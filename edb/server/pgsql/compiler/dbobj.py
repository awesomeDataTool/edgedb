#
# This source file is part of the EdgeDB open source project.
#
# Copyright 2008-present MagicStack Inc. and the EdgeDB authors.
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


import typing

from edb.lang.ir import ast as irast

from edb.lang.schema import objtypes as s_objtypes
from edb.lang.schema import links as s_links
from edb.lang.schema import objects as s_obj
from edb.lang.schema import pointers as s_pointers

from edb.server.pgsql import ast as pgast
from edb.server.pgsql import common
from edb.server.pgsql import types as pgtypes

from . import context


def range_for_material_objtype(
        objtype: s_objtypes.ObjectType,
        path_id: irast.PathId, *,
        include_overlays: bool=True,
        env: context.Environment) -> pgast.BaseRangeVar:

    from . import pathctx  # XXX: fix cycle

    objtype = objtype.material_type(env.schema)
    objtype_name = objtype.get_name(env.schema)

    table_schema_name, table_name = common.get_backend_name(
        env.schema, objtype, catenate=False)

    if objtype_name.module == 'schema':
        # Redirect all queries to schema tables to edgedbss
        table_schema_name = 'edgedbss'

    relation = pgast.Relation(
        schemaname=table_schema_name,
        name=table_name,
        path_id=path_id,
    )

    rvar = pgast.RangeVar(
        relation=relation,
        alias=pgast.Alias(
            aliasname=env.aliases.get(objtype_name.name)
        )
    )

    overlays = env.rel_overlays.get(objtype_name)
    if overlays and include_overlays:
        set_ops = []

        qry = pgast.SelectStmt()
        qry.from_clause.append(rvar)
        pathctx.put_path_value_rvar(qry, path_id, rvar, env=env)
        pathctx.put_path_bond(qry, path_id)

        set_ops.append(('union', qry))

        for op, cte in overlays:
            rvar = pgast.RangeVar(
                relation=cte,
                alias=pgast.Alias(
                    aliasname=env.aliases.get(hint=cte.name)
                )
            )

            qry = pgast.SelectStmt(
                from_clause=[rvar],
            )

            pathctx.put_path_value_rvar(qry, path_id, rvar, env=env)
            pathctx.put_path_bond(qry, path_id)

            if op == 'replace':
                op = 'union'
                set_ops = []

            set_ops.append((op, qry))

        rvar = range_from_queryset(set_ops, objtype, env=env)

    return rvar


def range_for_objtype(
        objtype: s_objtypes.ObjectType,
        path_id: irast.PathId, *,
        include_overlays: bool=True,
        env: context.Environment) -> pgast.BaseRangeVar:
    from . import pathctx  # XXX: fix cycle

    if not objtype.get_is_virtual(env.schema):
        rvar = range_for_material_objtype(
            objtype, path_id, include_overlays=include_overlays, env=env)
    else:
        # Union object types are represented as a UNION of selects
        # from their children, which is, for most purposes, equivalent
        # to SELECTing from a parent table.
        children = frozenset(objtype.children(env.schema))

        set_ops = []

        for child in children:
            c_rvar = range_for_objtype(
                child, path_id=path_id,
                include_overlays=include_overlays, env=env)

            qry = pgast.SelectStmt(
                from_clause=[c_rvar],
            )

            pathctx.put_path_value_rvar(qry, path_id, c_rvar, env=env)
            pathctx.put_path_bond(qry, path_id)

            set_ops.append(('union', qry))

        rvar = range_from_queryset(set_ops, objtype, env=env)

    rvar.query.is_distinct = True
    rvar.query.path_id = path_id

    return rvar


def range_for_set(
        ir_set: irast.Set, *,
        include_overlays: bool=True,
        env: context.Environment) -> pgast.BaseRangeVar:
    rvar = range_for_objtype(
        ir_set.stype, ir_set.path_id,
        include_overlays=include_overlays, env=env)

    return rvar


def table_from_ptrcls(
        ptrcls: s_links.Link, *,
        env: context.Environment) -> pgast.RangeVar:
    """Return a Table corresponding to a given Link."""
    table_schema_name, table_name = common.get_backend_name(
        env.schema, ptrcls, catenate=False)

    pname = ptrcls.get_shortname(env.schema)

    if pname.module == 'schema':
        # Redirect all queries to schema tables to edgedbss
        table_schema_name = 'edgedbss'

    relation = pgast.Relation(
        schemaname=table_schema_name, name=table_name)

    rvar = pgast.RangeVar(
        relation=relation,
        alias=pgast.Alias(
            aliasname=env.aliases.get(pname.name)
        )
    )

    return rvar


def range_for_ptrcls(
        ptrcls: s_links.Link, direction: s_pointers.PointerDirection, *,
        include_overlays: bool=True,
        env: context.Environment) -> pgast.BaseRangeVar:
    """"Return a Range subclass corresponding to a given ptr step.

    If `ptrcls` is a generic link, then a simple RangeVar is returned,
    otherwise the return value may potentially be a UNION of all tables
    corresponding to a set of specialized links computed from the given
    `ptrcls` taking source inheritance into account.
    """
    linkname = ptrcls.get_shortname(env.schema)
    endpoint = ptrcls.get_source(env.schema)

    tgt_col = pgtypes.get_pointer_storage_info(
        ptrcls, resolve_type=False, link_bias=True,
        schema=env.schema).column_name

    cols = [
        'std::source',
        tgt_col
    ]

    set_ops = []

    ptrclses = set()

    for source in {endpoint} | set(endpoint.descendants(env.schema)):
        # Sift through the descendants to see who has this link
        try:
            ptr = source.getptr(env.schema, linkname)
            src_ptrcls = ptr.material_type(env.schema)
        except KeyError:
            # This source has no such link, skip it
            continue
        else:
            if src_ptrcls in ptrclses:
                # Seen this link already
                continue
            ptrclses.add(src_ptrcls)

        table = table_from_ptrcls(src_ptrcls, env=env)

        qry = pgast.SelectStmt()
        qry.from_clause.append(table)
        qry.rptr_rvar = table

        # Make sure all property references are pulled up properly
        for colname in cols:
            selexpr = pgast.ColumnRef(
                name=[table.alias.aliasname, colname])
            qry.target_list.append(
                pgast.ResTarget(val=selexpr, name=colname))

        set_ops.append(('union', qry))

        overlays = env.rel_overlays.get(src_ptrcls.get_shortname(env.schema))
        if overlays and include_overlays:
            for op, cte in overlays:
                rvar = pgast.RangeVar(
                    relation=cte,
                    alias=pgast.Alias(
                        aliasname=env.aliases.get(cte.name)
                    )
                )

                qry = pgast.SelectStmt(
                    target_list=[
                        pgast.ResTarget(
                            val=pgast.ColumnRef(
                                name=[col]
                            )
                        )
                        for col in cols
                    ],
                    from_clause=[rvar],
                )
                set_ops.append((op, qry))

    rvar = range_from_queryset(set_ops, ptrcls, env=env)
    return rvar


def range_for_pointer(
        pointer: s_links.Link, *,
        env: context.Environment) -> pgast.BaseRangeVar:
    ptrcls = pointer.ptrcls
    if ptrcls.get_derived_from(env.schema) is not None:
        ptrcls = ptrcls.get_nearest_non_derived_parent(env.schema)

    return range_for_ptrcls(ptrcls, pointer.direction, env=env)


def range_from_queryset(
        set_ops: typing.Sequence[typing.Tuple[str, pgast.BaseRelation]],
        stype: s_obj.Object, *,
        env: context.Environment) -> pgast.BaseRangeVar:
    if len(set_ops) > 1:
        # More than one class table, generate a UNION/EXCEPT clause.
        qry = pgast.SelectStmt(
            all=True,
            larg=set_ops[0][1]
        )

        for op, rarg in set_ops[1:]:
            qry.op, qry.rarg = op, rarg
            qry = pgast.SelectStmt(
                all=True,
                larg=qry
            )

        qry = qry.larg

        rvar = pgast.RangeSubselect(
            subquery=qry,
            alias=pgast.Alias(
                aliasname=env.aliases.get(stype.get_shortname(env.schema).name)
            )
        )

    else:
        # Just one class table, so return it directly
        rvar = set_ops[0][1].from_clause[0]

    return rvar


def get_column(
        rvar: pgast.BaseRangeVar,
        colspec: typing.Union[str, pgast.ColumnRef], *,
        optional: bool=False, nullable: bool=None) -> pgast.ColumnRef:

    if isinstance(colspec, pgast.ColumnRef):
        colname = colspec.name[-1]
        if nullable is None:
            nullable = colspec.nullable
        optional = colspec.optional
    else:
        colname = colspec
        if nullable is None:
            # Assume the column is nullable unless told otherwise.
            nullable = True

    if rvar is None:
        name = [colname]
    else:
        name = [rvar.alias.aliasname, colname]

    return pgast.ColumnRef(name=name, nullable=nullable, optional=optional)


def rvar_for_rel(
        rel: pgast.BaseRelation, *,
        lateral: bool=False, colnames: typing.List[str]=[],
        env: context.Environment) -> pgast.BaseRangeVar:
    if isinstance(rel, pgast.Query):
        alias = env.aliases.get(rel.name or 'q')

        rvar = pgast.RangeSubselect(
            subquery=rel,
            alias=pgast.Alias(aliasname=alias, colnames=colnames),
            lateral=lateral,
        )
    else:
        alias = env.aliases.get(rel.name)

        rvar = pgast.RangeVar(
            relation=rel,
            alias=pgast.Alias(aliasname=alias, colnames=colnames)
        )

    return rvar


def get_rvar_var(
        rvar: typing.Optional[pgast.BaseRangeVar], var: pgast.OutputVar,
        *, optional: bool=False, nullable: bool=None) \
        -> typing.Union[pgast.ColumnRef, pgast.TupleVar]:

    assert isinstance(var, pgast.OutputVar)

    if isinstance(var, pgast.TupleVar):
        elements = []

        for el in var.elements:
            val = get_rvar_var(rvar, el.name)
            elements.append(
                pgast.TupleElement(
                    path_id=el.path_id, name=el.name, val=val))

        fieldref = pgast.TupleVar(elements, named=var.named)
    else:
        fieldref = get_column(rvar, var, optional=optional,
                              nullable=nullable)

    return fieldref


def add_rel_overlay(
        stype: s_objtypes.ObjectType, op: str, rel: pgast.BaseRelation, *,
        env: context.Environment) -> None:
    overlays = env.rel_overlays[stype.get_name(env.schema)]
    overlays.append((op, rel))


def cte_for_query(
        rel: pgast.Query, *,
        env: context.Environment) -> pgast.CommonTableExpr:
    return pgast.CommonTableExpr(
        query=rel,
        alias=pgast.Alias(
            aliasname=env.aliases.get(rel.name)
        )
    )


def cols_for_pointer(
        pointer: s_pointers.Pointer, *,
        env: context.Environment) -> typing.List[str]:
    cols = ['ptr_item_id']

    if isinstance(pointer, s_links.Link):
        for ptr in pointer.get_pointers(env.schema).objects(env.schema):
            cols.append(
                common.edgedb_name_to_pg_name(ptr.get_shortname(env.schema)))
    else:
        cols.extend(('std::source', 'std::target'))

    return cols
