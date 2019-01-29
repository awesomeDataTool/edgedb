#
# This source file is part of the EdgeDB open source project.
#
# Copyright 2016-present MagicStack Inc. and the EdgeDB authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

import asyncio

cimport cython
cimport cpython

from libc.stdint cimport int8_t, uint8_t, int16_t, uint16_t, \
                         int32_t, uint32_t, int64_t, uint64_t, \
                         UINT32_MAX

import immutables

from edb.server.pgproto cimport hton
from edb.server.pgproto.pgproto cimport (
    WriteBuffer,
    ReadBuffer,

    FRBuffer,
    frb_init,
    frb_read,
    frb_read_all,
    frb_get_len,
)

from edb.server.dbview cimport dbview

from edb.server import defines
from edb.server.backend import config
from edb.server.pgcon cimport pgcon
from edb.server.pgcon import errors as pgerror

from edb.schema import objects as s_obj

from edb import errors
from edb.common import debug


DEF FLUSH_BUFFER_AFTER = 100_000
cdef bytes ZERO_UUID = b'\x00' * 16
cdef bytes EMPTY_TUPLE_UUID = s_obj.get_known_type_id('empty-tuple').bytes


cdef bytes INIT_CON_SCRIPT = (b'''
    CREATE TEMPORARY TABLE _edgecon_state (
        name text NOT NULL,
        value text NOT NULL,
        type text NOT NULL CHECK(type = 'C' OR type = 'A'),
        UNIQUE(name, type)
    );

    CREATE TEMPORARY TABLE _edgecon_current_savepoint (
        sp_id bigint NOT NULL,
        _sentinel bigint DEFAULT -1,
        UNIQUE(_sentinel)
    );

    INSERT INTO _edgecon_state(name, value, type)
    VALUES ('', \'''' +
       defines.DEFAULT_MODULE_ALIAS.replace("'", "''").encode() +
    b'''\', 'A');
    '''
)


@cython.final
cdef class EdgeConnection:

    def __init__(self, server):
        self._con_status = EDGECON_NEW
        self._id = server.new_edgecon_id()
        self.port = server

        self.loop = server.get_loop()
        self.dbview = None
        self.backend = None

        self._transport = None
        self.buffer = ReadBuffer()

        self._parsing = True
        self._reading_messages = False

        self._main_task = None
        self._startup_msg_waiter = self.loop.create_future()
        self._msg_take_waiter = None

        self._last_anon_compiled = None

        self._write_buf = None

        self.debug = debug.flags.server_proto
        self.query_cache_enabled = not (debug.flags.disable_qcache or
                                        debug.flags.edgeql_compile)

    def debug_print(self, *args):
        print(
            '::EDGEPROTO::',
            f'id:{self._id}',
            f'in_tx:{int(self.dbview.in_tx())}',
            f'tx_error:{int(self.dbview.in_tx_error())}',
            *args,
        )

    cdef write(self, WriteBuffer buf):
        # One rule for this method: don't write partial messages.
        if self._write_buf is not None:
            self._write_buf.write_buffer(buf)
            if self._write_buf.len() >= FLUSH_BUFFER_AFTER:
                self.flush()
        else:
            self._write_buf = buf

    cdef abort(self):
        self._con_status = EDGECON_BAD
        if self._transport is not None:
            self._transport.abort()
            self._transport = None
        if self.backend is not None:
            self.loop.create_task(self.backend.close())
            self.backend = None

    cdef flush(self):
        if self._transport is None:
            # could be if the connection is lost and a coroutine
            # method is finalizing.
            raise ConnectionAbortedError
        if self._write_buf is not None and self._write_buf.len():
            buf = self._write_buf
            self._write_buf = None
            self._transport.write(buf)

    async def wait_for_message(self):
        if self.buffer.take_message():
            return
        self._msg_take_waiter = self.loop.create_future()
        await self._msg_take_waiter

    async def auth(self):
        cdef:
            int16_t hi
            int16_t lo
            char mtype

            WriteBuffer msg_buf
            WriteBuffer buf

        await self._startup_msg_waiter

        hi = self.buffer.read_int16()
        lo = self.buffer.read_int16()
        if hi != 1 or lo != 0:
            raise errors.UnsupportedProtocolVersionError

        self._con_status = EDGECON_STARTED

        await self.wait_for_message()
        mtype = self.buffer.get_message_type()
        if mtype == b'0':
            user = self.buffer.read_utf8()
            password = self.buffer.read_utf8()
            database = self.buffer.read_utf8()

            # XXX implement auth
            dbv = self.port.new_view(
                dbname=database, user=user,
                query_cache=self.query_cache_enabled)
            assert type(dbv) is dbview.DatabaseConnectionView
            self.dbview = <dbview.DatabaseConnectionView>dbv

            self.backend = await self.port.new_backend(
                dbname=database, dbver=self.dbview.dbver)

            buf = WriteBuffer()

            msg_buf = WriteBuffer.new_message(b'R')
            msg_buf.write_int32(0)
            msg_buf.end_message()
            buf.write_buffer(msg_buf)

            msg_buf = WriteBuffer.new_message(b'K')
            msg_buf.write_int32(0)  # TODO: should send ID of this connection
            msg_buf.end_message()
            buf.write_buffer(msg_buf)

            if self.port.in_dev_mode():
                msg_buf = WriteBuffer.new_message(b'S')
                msg_buf.write_utf8('pgaddr')
                msg_buf.write_utf8(str(self.backend.pgcon.get_pgaddr()))
                msg_buf.end_message()
                buf.write_buffer(msg_buf)

            msg_buf = WriteBuffer.new_message(b'Z')
            msg_buf.write_byte(b'I')
            msg_buf.end_message()
            buf.write_buffer(msg_buf)

            self.write(buf)
            self.flush()

            self.buffer.finish_message()

        else:
            self.fallthrough(False)

    async def initcon(self):
        await self.backend.pgcon.simple_query(
            INIT_CON_SCRIPT,
            ignore_data=True)

    async def recover_current_tx_info(self):
        ret = await self.backend.pgcon.simple_query(b'''
            SELECT s1.name AS n, s1.value AS v, s1.type AS t
                FROM _edgecon_state s1
            UNION ALL
            SELECT '' AS n, s2.sp_id::text AS v, 'S' AS t
                FROM _edgecon_current_savepoint s2;
        ''', ignore_data=False)

        conf = aliases = immutables.Map()
        sp_id = None

        if ret:
            for sname, svalue, stype in ret:
                sname = sname.decode()
                svalue = svalue.decode()

                if stype == b'C':
                    pyval = config._setting_val_from_eql(
                        self.backend.std_schema, sname, svalue)
                    conf = conf.set(sname, pyval)
                elif stype == b'A':
                    if not sname:
                        sname = None
                    aliases = aliases.set(sname, svalue)
                else:
                    assert stype == b'S' and not sname
                    sp_id = int(svalue)

        if self.debug:
            self.debug_print('RECOVER SP/ALIAS/CONF', sp_id, aliases, conf)

        if self.dbview.in_tx():
            self.dbview.rollback_tx_to_savepoint(sp_id, aliases, conf)
        else:
            self.dbview.recover_aliases_and_config(aliases, conf)

    #############

    async def _compile(self, bytes eql, bint json_mode):
        if self.dbview.in_tx_error():
            self.dbview.raise_in_tx_error()

        if self.dbview.in_tx():
            units = await self.backend.compiler.call(
                'compile_eql_in_tx',
                self.dbview.txid,
                eql,
                json_mode,
                'single')
        else:
            units = await self.backend.compiler.call(
                'compile_eql',
                self.dbview.dbver,
                eql,
                self.dbview.modaliases,
                self.dbview.config,
                json_mode,
                'single')

        return units[0]

    async def _compile_script(self, bytes eql, bint json_mode,
                              str stmt_mode):

        if self.dbview.in_tx_error():
            self.dbview.raise_in_tx_error()

        if self.dbview.in_tx():
            return await self.backend.compiler.call(
                'compile_eql_in_tx',
                self.dbview.txid,
                eql,
                json_mode,
                stmt_mode)
        else:
            return await self.backend.compiler.call(
                'compile_eql',
                self.dbview.dbver,
                eql,
                self.dbview.modaliases,
                self.dbview.config,
                json_mode,
                stmt_mode)

    async def _compile_rollback(self, bytes eql):
        assert self.dbview.in_tx_error()
        try:
            return await self.backend.compiler.call(
                'try_compile_rollback', self.dbview.dbver, eql)
        except Exception:
            self.dbview.raise_in_tx_error()

    async def legacy(self):
        cdef:
            WriteBuffer msg
            WriteBuffer packet

        lang = self.buffer.read_byte()
        graphql = lang == b'g'
        if not graphql:
            raise errors.BinaryProtocolError('only graphql is supported')

        gql = self.buffer.read_null_str()
        self.buffer.finish_message()
        if not gql:
            raise errors.BinaryProtocolError('empty query')

        if self.debug:
            self.debug_print('LEGACY', gql)

        if self.dbview.in_tx():
            raise errors.TransactionError(
                'GraphQL queries cannot run in a transaction block')

        compiled = await self.backend.compiler.call(
            'compile_graphql',
            self.dbview.dbver,
            gql,
            self.dbview.modaliases,
            self.dbview.config)

        self.dbview.start(compiled)
        try:
            res = await self.backend.pgcon.simple_query(
                b';'.join(compiled.sql), ignore_data=False)
        except ConnectionAbortedError:
            raise
        except Exception as ex:
            self.dbview.on_error(compiled)
            if not self.backend.pgcon.in_tx() and self.dbview.in_tx():
                # COMMIT command can fail, in which case the
                # transaction is finished.  This check workarounds
                # that (until a better solution is found.)
                self.dbview.abort_tx()
                await self.recover_current_tx_info()
            raise
        else:
            self.dbview.on_success(compiled)

        if res is not None:
            if len(res) > 1:
                raise errors.TransactionError(
                    'GraphQL query returned more than one data row')
            out = list(r[0] for r in res if r)
            if out:
                result = out[0]
            else:
                result = b'null'
        else:
            result = b'null'

        msg = WriteBuffer.new_message(b'L')
        msg.write_bytes(result)

        packet = WriteBuffer.new()
        packet.write_buffer(msg.end_message())
        packet.write_buffer(self.pgcon_last_sync_status())
        self.write(packet)
        self.flush()

    async def _recover_script_error(self, eql):
        assert self.dbview.in_tx_error()

        compiled, num_remain = await self._compile_rollback(eql)
        await self.backend.pgcon.simple_query(
            b';'.join(compiled.sql), ignore_data=True)

        if compiled.tx_savepoint_rollback:
            if self.debug:
                self.debug_print(f'== RECOVERY: ROLLBACK TO SP')
            await self.recover_current_tx_info()
        else:
            if self.debug:
                self.debug_print('== RECOVERY: ROLLBACK')
            assert compiled.tx_rollback
            self.dbview.abort_tx()

        if num_remain:
            return 'skip_first'
        else:
            return 'done'

    async def simple_query(self):
        cdef:
            WriteBuffer msg
            WriteBuffer packet

        eql = self.buffer.read_null_str()
        self.buffer.finish_message()
        if not eql:
            raise errors.BinaryProtocolError('empty query')

        if self.debug:
            self.debug_print('SIMPLE QUERY', eql)

        stmt_mode = 'all'
        if self.dbview.in_tx_error():
            stmt_mode = await self._recover_script_error(eql)
            if stmt_mode == 'done':
                packet = WriteBuffer.new()
                packet.write_buffer(
                    WriteBuffer.new_message(b'C').end_message())
                packet.write_buffer(self.pgcon_last_sync_status())
                self.write(packet)
                self.flush()
                return

        units = await self._compile_script(eql, False, stmt_mode)

        for unit in units:
            self.dbview.start(unit)
            try:
                await self.backend.pgcon.simple_query(
                    b';'.join(unit.sql), ignore_data=True)
            except ConnectionAbortedError:
                raise
            except Exception:
                self.dbview.on_error(unit)
                if not self.backend.pgcon.in_tx() and self.dbview.in_tx():
                    # COMMIT command can fail, in which case the
                    # transaction is finished.  This check workarounds
                    # that (until a better solution is found.)
                    self.dbview.abort_tx()
                    await self.recover_current_tx_info()
                raise
            else:
                self.dbview.on_success(unit)

        packet = WriteBuffer.new()
        packet.write_buffer(WriteBuffer.new_message(b'C').end_message())
        packet.write_buffer(self.pgcon_last_sync_status())
        self.write(packet)
        self.flush()

    async def _parse(self, bytes eql, bint json_mode):
        if self.debug:
            self.debug_print('PARSE', eql)

        compiled = self.dbview.lookup_compiled_query(eql, json_mode)
        cached = True
        if compiled is None:
            # Cache miss; need to compile this query.
            cached = False

            if self.dbview.in_tx_error():
                # The current transaction is aborted; only
                # ROLLBACK or ROLLBACK TO TRANSACTION could be parsed;
                # try doing just that.
                compiled, num_remain = await self._compile_rollback(eql)
                if num_remain:
                    # Raise an error if there were more than just a
                    # ROLLBACK in that 'eql' string.
                    self.dbview.raise_in_tx_error()
            else:
                compiled = await self._compile(eql, json_mode)
        elif self.dbview.in_tx_error():
            # We have a cached QueryUnit for this 'eql', but the current
            # transaction is aborted.  We can only complete this Parse
            # command if the cached QueryUnit is a 'ROLLBACK' or
            # 'ROLLBACK TO SAVEPOINT' command.
            if not (compiled.tx_rollback or compiled.tx_savepoint_rollback):
                self.dbview.raise_in_tx_error()

        await self.backend.pgcon.parse_execute(
            1,          # =parse
            0,          # =execute
            compiled,   # =query
            self,       # =edgecon
            None,       # =bind_data
            0,          # =send_sync
            0,          # =use_prep_stmt
        )

        if not cached and compiled.cacheable:
            self.dbview.cache_compiled_query(eql, json_mode, compiled)

        self._last_anon_compiled = compiled
        return compiled

    cdef int32_t compute_parse_flags(self, compiled) except -1:
        cdef:
            int32_t flags = 0

        if compiled.has_result:
            flags |= EdgeParseFlags.PARSE_HAS_RESULT
        if compiled.singleton_result:
            flags |= EdgeParseFlags.PARSE_SINGLETON_RESULT

        return flags

    cdef is_json_mode(self, bytes mode):
        if mode == b'j':
            # json
            return True
        elif mode == b'b':
            # binary
            return False
        else:
            raise errors.BinaryProtocolError(
                f'unknown output mode "{repr(mode)[2:-1]}"')

    async def parse(self):
        cdef:
            bint json_mode
            bytes eql

        self._last_anon_compiled = None

        json_mode = self.is_json_mode(self.buffer.read_byte())

        stmt_name = self.buffer.read_utf8()
        if stmt_name:
            raise errors.UnsupportedFeatureError(
                'prepared statements are not yet supported')

        eql = self.buffer.read_null_str()
        if not eql:
            raise errors.BinaryProtocolError('empty query')

        compiled = await self._parse(eql, json_mode)

        buf = WriteBuffer.new_message(b'1')  # ParseComplete
        buf.write_int32(self.compute_parse_flags(compiled))
        buf.write_bytes(compiled.in_type_id)
        buf.write_bytes(compiled.out_type_id)
        buf.end_message()

        self.write(buf)

    #############

    cdef make_describe_response(self, compiled):
        cdef:
            WriteBuffer msg

        msg = WriteBuffer.new_message(b'T')

        msg.write_int32(self.compute_parse_flags(compiled))

        in_data = compiled.in_type_data
        msg.write_bytes(compiled.in_type_id)
        msg.write_int16(len(in_data))
        msg.write_bytes(in_data)

        out_data = compiled.out_type_data
        msg.write_bytes(compiled.out_type_id)
        msg.write_int16(len(out_data))
        msg.write_bytes(out_data)

        msg.end_message()
        return msg

    async def describe(self):
        cdef:
            char rtype
            WriteBuffer msg

        rtype = self.buffer.read_byte()
        if rtype == b'T':
            # describe "type id"
            stmt_name = self.buffer.read_utf8()

            if stmt_name:
                raise errors.UnsupportedFeatureError(
                    'prepared statements are not yet supported')
            else:
                if self._last_anon_compiled is None:
                    raise errors.TypeSpecNotFoundError(
                        'no prepared anonymous statement found')

                msg = self.make_describe_response(self._last_anon_compiled)
                self.write(msg)

        else:
            raise errors.BinaryProtocolError(
                f'unsupported "describe" message mode {chr(rtype)!r}')

    async def _execute(self, compiled, bind_args,
                       bint parse, bint use_prep_stmt):
        if self.dbview.in_tx_error():
            if not (compiled.tx_savepoint_rollback or compiled.tx_rollback):
                self.dbview.raise_in_tx_error()

            await self.backend.pgcon.simple_query(
                b';'.join(compiled.sql), ignore_data=True)

            if compiled.tx_savepoint_rollback:
                await self.recover_current_tx_info()
            else:
                assert compiled.tx_rollback
                self.dbview.abort_tx()

            self.write(WriteBuffer.new_message(b'C').end_message())
            return

        bound_args_buf = self.recode_bind_args(bind_args)

        process_sync = False
        if self.buffer.take_message_type(b'S'):
            # A "Sync" message follows this "Execute" message;
            # send it right away.
            process_sync = True

        try:
            self.dbview.start(compiled)
            try:
                await self.backend.pgcon.parse_execute(
                    parse,              # =parse
                    1,                  # =execute
                    compiled,           # =query
                    self,               # =edgecon
                    bound_args_buf,     # =bind_data
                    process_sync,       # =send_sync
                    use_prep_stmt,      # =use_prep_stmt
                )
            except ConnectionAbortedError:
                raise
            except Exception:
                self.dbview.on_error(compiled)
                if not self.backend.pgcon.in_tx() and self.dbview.in_tx():
                    # COMMIT command can fail, in which case the
                    # transaction is finished.  This check workarounds
                    # that (until a better solution is found.)
                    self.dbview.abort_tx()
                    await self.recover_current_tx_info()
                raise
            else:
                self.dbview.on_success(compiled)

            self.write(WriteBuffer.new_message(b'C').end_message())

            if process_sync:
                self.write(self.pgcon_last_sync_status())
                self.flush()
        except Exception:
            if process_sync:
                self.buffer.put_message()
            raise
        else:
            if process_sync:
                self.buffer.finish_message()

    async def execute(self):
        cdef:
            WriteBuffer bound_args_buf
            bint process_sync

        stmt_name = self.buffer.read_utf8()
        bind_args = self.buffer.consume_message()
        compiled = None

        if self.debug:
            self.debug_print('EXECUTE')

        if stmt_name:
            raise errors.UnsupportedFeatureError(
                'prepared statements are not yet supported')
        else:
            if self._last_anon_compiled is None:
                raise errors.BinaryProtocolError(
                    'no prepared anonymous statement found')

            compiled = self._last_anon_compiled

        await self._execute(compiled, bind_args, False, False)

    async def opportunistic_execute(self):
        cdef:
            WriteBuffer bound_args_buf
            bint process_sync
            int32_t parse_flags
            bytes in_tid
            bytes out_tid
            bytes bound_args

        json_mode = self.is_json_mode(self.buffer.read_byte())
        query = self.buffer.read_null_str()
        parse_flags = self.buffer.read_int32()
        in_tid = self.buffer.read_bytes(16)
        out_tid = self.buffer.read_bytes(16)
        bind_args = self.buffer.consume_message()

        if not query:
            raise errors.BinaryProtocolError('empty query')

        compiled = self.dbview.lookup_compiled_query(query, json_mode)
        if compiled is None:
            if self.debug:
                self.debug_print('OPPORTUNISTIC EXECUTE /REPARSE', query)

            compiled = await self._parse(query, json_mode)

        expected_singleton_result = bool(
            parse_flags & EdgeParseFlags.PARSE_SINGLETON_RESULT)

        if (compiled.in_type_id != in_tid or
                compiled.out_type_id != out_tid or
                bool(compiled.singleton_result) != expected_singleton_result):
            # The client has outdated information about type specs.
            if self.debug:
                self.debug_print('OPPORTUNISTIC EXECUTE /MISMATCH', query)

            self.write(self.make_describe_response(compiled))
            return

        if self.debug:
            self.debug_print('OPPORTUNISTIC EXECUTE', query)

        await self._execute(
            compiled, bind_args, True, bool(compiled.sql_hash))

    async def sync(self):
        cdef:
            WriteBuffer buf

        self.buffer.consume_message()

        await self.backend.pgcon.sync()
        self.write(self.pgcon_last_sync_status())

        if self.debug:
            self.debug_print(
                'SYNC', (<pgcon.PGProto>(self.backend.pgcon)).xact_status)

        self.flush()

    async def main(self):
        cdef:
            char mtype

        try:
            await self.auth()
            await self.initcon()
        except Exception as ex:
            if self._transport is not None:
                # If there's no transport it means that the connection
                # was aborted, in which case we don't really care about
                # reporting the exception.

                await self.write_error(ex)
                self.abort()

                self.loop.call_exception_handler({
                    'message': (
                        'unhandled error in edgedb protocol while '
                        'accepting new connection'
                    ),
                    'exception': ex,
                    'protocol': self,
                    'transport': self._transport,
                    'task': self._main_task,
                })

            return

        try:
            while True:
                if not self.buffer.take_message():
                    await self.wait_for_message()
                mtype = self.buffer.get_message_type()

                flush_sync_on_error = False

                try:
                    if mtype == b'P':
                        await self.parse()

                    elif mtype == b'D':
                        await self.describe()

                    elif mtype == b'E':
                        await self.execute()

                    elif mtype == b'O':
                        await self.opportunistic_execute()

                    elif mtype == b'Q':
                        flush_sync_on_error = True
                        await self.simple_query()

                    elif mtype == b'S':
                        await self.sync()

                    elif mtype == b'L':
                        flush_sync_on_error = True
                        await self.legacy()
                        self.flush()

                    else:
                        self.fallthrough(False)

                except ConnectionAbortedError:
                    raise

                except asyncio.CancelledError:
                    raise

                except Exception as ex:
                    self.dbview.tx_error()
                    self.buffer.finish_message()

                    await self.write_error(ex)

                    if flush_sync_on_error:
                        self.write(self.pgcon_last_sync_status())
                        self.flush()
                    else:
                        await self.recover_from_error()

                else:
                    self.buffer.finish_message()

        except asyncio.CancelledError:
            # Happens when the connection is aborted, the backend is
            # being closed and propagates CancelledError to all
            # EdgeCon methods that await on, say, the compiler process.
            # We shouldn't have CancelledErrors otherwise, therefore,
            # in this situation we just silently exit.
            self.abort()

        except ConnectionAbortedError:
            return

        except Exception as ex:
            # We can only be here if an exception occurred during
            # handling another exception, in which case, the only
            # sane option is to abort the connection.

            self.loop.call_exception_handler({
                'message': (
                    'unhandled error in edgedb protocol while '
                    'handling an error'
                ),
                'exception': ex,
                'protocol': self,
                'transport': self._transport,
                'task': self._main_task,
            })

            self.abort()

    async def recover_from_error(self):
        # Consume all messages until sync.

        while True:
            if not self.buffer.take_message():
                await self.wait_for_message()
            mtype = self.buffer.get_message_type()

            if mtype == b'S':
                await self.sync()
                return
            else:
                self.buffer.discard_message()

    async def write_error(self, exc):
        cdef:
            WriteBuffer buf

        if debug.flags.server:
            self.loop.call_exception_handler({
                'message': (
                    'an error in edgedb protocol'
                ),
                'exception': exc,
                'protocol': self,
                'transport': self._transport,
            })

        exc_code = None

        if isinstance(exc, pgerror.BackendError):
            try:
                exc = await self.backend.compiler.call(
                    'interpret_backend_error',
                    self.dbview.dbver,
                    exc.fields)
            except Exception as ex:
                exc = RuntimeError(
                    'unhandled error while calling interpret_backend_error()')

        fields = None
        if (isinstance(exc, errors.EdgeDBError) and
                type(exc) is not errors.EdgeDBError):
            exc_code = exc.get_code()
            fields = exc._attrs

        if not exc_code:
            exc_code = errors.InternalServerError.get_code()

        buf = WriteBuffer.new_message(b'E')
        buf.write_int32(<int32_t><uint32_t>exc_code)

        buf.write_utf8(str(exc))

        if fields is not None:
            for k, v in fields.items():
                assert len(k) == 1
                buf.write_byte(ord(k.encode()))
                buf.write_utf8(str(v))

        buf.write_byte(b'\x00')

        buf.end_message()

        self.write(buf)

    cdef pgcon_last_sync_status(self):
        cdef:
            pgcon.PGTransactionStatus xact_status
            WriteBuffer buf

        xact_status = <pgcon.PGTransactionStatus>(
            (<pgcon.PGProto>self.backend.pgcon).xact_status)

        buf = WriteBuffer.new_message(b'Z')
        if xact_status == pgcon.PQTRANS_IDLE:
            buf.write_byte(b'I')
        elif xact_status == pgcon.PQTRANS_INTRANS:
            buf.write_byte(b'T')
        elif xact_status == pgcon.PQTRANS_INERROR:
            buf.write_byte(b'E')
        else:
            raise errors.InternalServerError(
                'unknown postgres connection status')
        return buf.end_message()

    cdef fallthrough(self, bint ignore_unhandled):
        cdef:
            char mtype = self.buffer.get_message_type()

        if mtype == b'H':
            # Flush
            self.flush()
            self.buffer.discard_message()
            return

        if ignore_unhandled:
            self.buffer.discard_message()
        else:
            raise errors.BinaryProtocolError(
                f'unexpected message type {chr(mtype)!r}')

    cdef WriteBuffer recode_bind_args(self, bytes bind_args):
        cdef:
            FRBuffer in_buf
            WriteBuffer out_buf = WriteBuffer.new()
            int32_t argsnum
            ssize_t in_len

        assert cpython.PyBytes_CheckExact(bind_args)
        frb_init(
            &in_buf,
            cpython.PyBytes_AS_STRING(bind_args),
            cpython.Py_SIZE(bind_args))

        # all parameters are in binary
        out_buf.write_int32(0x00010001)

        frb_read(&in_buf, 4)  # ignore buffer length

        # number of elements in the tuple
        argsnum = hton.unpack_int32(frb_read(&in_buf, 4))

        out_buf.write_int16(<int16_t>argsnum)

        in_len = frb_get_len(&in_buf)
        out_buf.write_cstr(frb_read_all(&in_buf), in_len)

        # All columns are in binary format
        out_buf.write_int32(0x00010001)
        return out_buf

    def connection_made(self, transport):
        if self._con_status != EDGECON_NEW:
            raise errors.BinaryProtocolError(
                'invalid connection status while establishing the connection')
        self._transport = transport
        self._main_task = self.loop.create_task(self.main())

    def connection_lost(self, exc):
        if (self._msg_take_waiter is not None and
                not self._msg_take_waiter.done()):
            self._msg_take_waiter.set_exception(ConnectionAbortedError())
            self._msg_take_waiter = None

        self.abort()

    def pause_writing(self):
        pass

    def resume_writing(self):
        pass

    def data_received(self, data):
        self.buffer.feed_data(data)

        if self._con_status == EDGECON_NEW and self.buffer.len() >= 4:
            self._startup_msg_waiter.set_result(True)

        elif self._msg_take_waiter is not None and self.buffer.take_message():
            self._msg_take_waiter.set_result(True)
            self._msg_take_waiter = None

    def eof_received(self):
        pass