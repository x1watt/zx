// Syntax tree of the zxdb SQL dialect (docs/zxdb-sql.md).

// ------------------------------------------------------------ expressions

abstract class Expr {
  const Expr();
}

class LitExpr extends Expr {
  final Object? value;
  const LitExpr(this.value);
}

/// CURRENT_TIME / CURRENT_DATE / CURRENT_TIMESTAMP.
class CurrentTimeExpr extends Expr {
  final String kind;
  const CurrentTimeExpr(this.kind);
}

class ParamExpr extends Expr {
  /// 1-based parameter index.
  final int index;
  final String? name;
  const ParamExpr(this.index, this.name);
}

class ColumnExpr extends Expr {
  final String? table;
  final String column;
  const ColumnExpr(this.table, this.column);
}

class UnaryExpr extends Expr {
  final String op; // '-', '+', '~', 'NOT'
  final Expr e;
  const UnaryExpr(this.op, this.e);
}

class BinaryExpr extends Expr {
  /// '||','*','/','%','+','-','<<','>>','&','|','<','<=','>','>=','=',
  /// '!=','IS','IS NOT','AND','OR','->','->>'
  final String op;
  final Expr l, r;
  const BinaryExpr(this.op, this.l, this.r);
}

class LikeExpr extends Expr {
  final String op; // LIKE, GLOB, REGEXP, MATCH
  final bool not;
  final Expr e, pattern;
  final Expr? escape;
  const LikeExpr(this.op, this.not, this.e, this.pattern, this.escape);
}

class BetweenExpr extends Expr {
  final bool not;
  final Expr e, lo, hi;
  const BetweenExpr(this.not, this.e, this.lo, this.hi);
}

class InListExpr extends Expr {
  final bool not;
  final Expr e;
  final List<Expr> list;
  const InListExpr(this.not, this.e, this.list);
}

class InSelectExpr extends Expr {
  final bool not;
  final Expr e;
  final SelectStmt select;
  const InSelectExpr(this.not, this.e, this.select);
}

class IsNullExpr extends Expr {
  final bool not;
  final Expr e;
  const IsNullExpr(this.not, this.e);
}

class CaseExpr extends Expr {
  final Expr? base;
  final List<(Expr, Expr)> whens;
  final Expr? orElse;
  const CaseExpr(this.base, this.whens, this.orElse);
}

class CastExpr extends Expr {
  final Expr e;
  final String type;
  const CastExpr(this.e, this.type);
}

class CollateExpr extends Expr {
  final Expr e;
  final String collation;
  const CollateExpr(this.e, this.collation);
}

class FuncExpr extends Expr {
  final String name; // lower case
  final List<Expr> args;
  final bool distinct;
  final bool star; // count(*)
  final Expr? filter;
  final List<OrderTerm>? orderBy; // group_concat(x ORDER BY y)
  const FuncExpr(this.name, this.args,
      {this.distinct = false, this.star = false, this.filter, this.orderBy});
}

class SubqueryExpr extends Expr {
  final SelectStmt select;
  const SubqueryExpr(this.select);
}

class ExistsExpr extends Expr {
  final SelectStmt select;
  const ExistsExpr(this.select);
}

/// A parenthesised list (a, b), used for row values in IN and SET.
class RowExpr extends Expr {
  final List<Expr> items;
  const RowExpr(this.items);
}

class RaiseExpr extends Expr {
  final String action;
  final String? message;
  const RaiseExpr(this.action, this.message);
}

// ------------------------------------------------------------ select

class OrderTerm {
  final Expr e;
  final bool desc;
  final bool? nullsFirst; // null: default (NULLs smallest)
  const OrderTerm(this.e, this.desc, this.nullsFirst);
}

class ResultColumn {
  final Expr? e; // null for * or t.*
  final String? starTable; // for t.*
  final bool star;
  final String? alias;
  final String text; // source text for the column name
  const ResultColumn(this.e, this.alias, this.text,
      {this.star = false, this.starTable});
}

/// Time travel on a table reference.
class AsOf {
  final Expr? time; // text date or number of seconds / ns
  final Expr? generation;
  const AsOf({this.time, this.generation});
}

abstract class FromSource {
  String? get alias;
}

class TableSource extends FromSource {
  final String name;
  @override
  final String? alias;
  final AsOf? asOf;
  final String? indexedBy;
  final bool notIndexed;
  final bool history; // HISTORY OF name
  TableSource(this.name, this.alias,
      {this.asOf, this.indexedBy, this.notIndexed = false, this.history = false});
}

class SubquerySource extends FromSource {
  final SelectStmt select;
  @override
  final String? alias;
  SubquerySource(this.select, this.alias);
}

class FuncSource extends FromSource {
  final String name;
  final List<Expr> args;
  @override
  final String? alias;
  FuncSource(this.name, this.args, this.alias);
}

class JoinItem {
  /// '' for the first item, ',' for a comma join, else 'INNER', 'LEFT',
  /// 'CROSS', 'RIGHT', 'FULL'.
  final String type;
  final bool natural;
  final FromSource source;
  final Expr? on;
  final List<String>? using;
  const JoinItem(this.type, this.source,
      {this.natural = false, this.on, this.using});
}

abstract class SelectBody {}

class SelectCore extends SelectBody {
  final bool distinct;
  final List<ResultColumn> columns;
  final List<JoinItem> from;
  final Expr? where;
  final List<Expr> groupBy;
  final Expr? having;
  SelectCore(this.distinct, this.columns, this.from, this.where, this.groupBy,
      this.having);
}

class ValuesCore extends SelectBody {
  final List<List<Expr>> rows;
  ValuesCore(this.rows);
}

class CompoundSelect extends SelectBody {
  final List<SelectBody> parts; // cores (never compound)
  final List<String> ops; // UNION, UNION ALL, INTERSECT, EXCEPT
  CompoundSelect(this.parts, this.ops);
}

class Cte {
  final String name;
  final List<String>? columns;
  final SelectStmt select;
  final bool? materialized;
  const Cte(this.name, this.columns, this.select, this.materialized);
}

class WithClause {
  final bool recursive;
  final List<Cte> ctes;
  const WithClause(this.recursive, this.ctes);
}

// ------------------------------------------------------------ statements

abstract class Stmt {
  /// Source text of the statement.
  String sql = '';
}

class SelectStmt extends Stmt {
  final WithClause? withClause;
  final SelectBody body;
  final List<OrderTerm> orderBy;
  final Expr? limit;
  final Expr? offset;
  SelectStmt(this.withClause, this.body, this.orderBy, this.limit, this.offset);
}

class Upsert {
  final List<Expr>? target; // conflict target columns
  final Expr? targetWhere;
  final bool doNothing;
  final List<SetClause> sets;
  final Expr? where;
  const Upsert(this.target, this.targetWhere, this.doNothing, this.sets,
      this.where);
}

class SetClause {
  final List<String> columns;
  final Expr value;
  const SetClause(this.columns, this.value);
}

class InsertStmt extends Stmt {
  final WithClause? withClause;
  final String? orAction; // REPLACE, IGNORE, ABORT, FAIL, ROLLBACK
  final String table;
  final String? alias;
  final List<String>? columns;
  final SelectStmt? select; // VALUES are a SelectStmt with a ValuesCore
  final bool defaultValues;
  final List<Upsert> upserts;
  final List<ResultColumn>? returning;
  InsertStmt(this.withClause, this.orAction, this.table, this.alias,
      this.columns, this.select, this.defaultValues, this.upserts,
      this.returning);
}

class UpdateStmt extends Stmt {
  final WithClause? withClause;
  final String? orAction;
  final String table;
  final String? alias;
  final List<SetClause> sets;
  final List<JoinItem>? from;
  final Expr? where;
  final List<ResultColumn>? returning;
  UpdateStmt(this.withClause, this.orAction, this.table, this.alias, this.sets,
      this.from, this.where, this.returning);
}

class DeleteStmt extends Stmt {
  final WithClause? withClause;
  final String table;
  final String? alias;
  final Expr? where;
  final List<ResultColumn>? returning;
  DeleteStmt(
      this.withClause, this.table, this.alias, this.where, this.returning);
}

class ColumnConstraint {
  final String kind; // PK, NOTNULL, UNIQUE, DEFAULT, CHECK, COLLATE, NULL, REFERENCES, GENERATED
  final Expr? expr;
  final bool desc;
  final bool autoincrement;
  final String? conflict;
  final String? collation;
  const ColumnConstraint(this.kind,
      {this.expr,
      this.desc = false,
      this.autoincrement = false,
      this.conflict,
      this.collation});
}

class ColumnDefAst {
  final String name;
  final String? type;
  final List<ColumnConstraint> constraints;
  const ColumnDefAst(this.name, this.type, this.constraints);
}

class IndexedColumn {
  final Expr e; // usually ColumnExpr
  final String? collation;
  final bool desc;
  const IndexedColumn(this.e, this.collation, this.desc);
}

class TableConstraintAst {
  final String kind; // PK, UNIQUE, CHECK, FK
  final List<IndexedColumn> columns;
  final Expr? check;
  final String? conflict;
  const TableConstraintAst(this.kind, this.columns, this.check, this.conflict);
}

class CreateTableStmt extends Stmt {
  final bool ifNotExists;
  final bool temp;
  final String name;
  final List<ColumnDefAst> columns;
  final List<TableConstraintAst> constraints;
  final Map<String, Object?> options;
  final SelectStmt? asSelect;
  final bool withoutRowid;
  final bool strict;
  CreateTableStmt(this.ifNotExists, this.temp, this.name, this.columns,
      this.constraints, this.options, this.asSelect,
      {this.withoutRowid = false, this.strict = false});
}

class CreateIndexStmt extends Stmt {
  final bool unique;
  final bool ifNotExists;
  final String name;
  final String table;
  final List<IndexedColumn> columns;
  final Expr? where;
  CreateIndexStmt(this.unique, this.ifNotExists, this.name, this.table,
      this.columns, this.where);
}

class CreateViewStmt extends Stmt {
  final bool ifNotExists;
  final String name;
  final List<String>? columns;
  final SelectStmt select;
  CreateViewStmt(this.ifNotExists, this.name, this.columns, this.select);
}

/// DROP TABLE / INDEX / VIEW / KV STORE / TIMESERIES / ROLLUP.
class DropStmt extends Stmt {
  final String kind; // TABLE, INDEX, VIEW, KV STORE, TIMESERIES, ROLLUP
  final bool ifExists;
  final String name;
  DropStmt(this.kind, this.ifExists, this.name);
}

class AlterTableStmt extends Stmt {
  final String table;
  final String action; // RENAME TO, RENAME COLUMN, ADD COLUMN, DROP COLUMN, SET
  final String? newName;
  final String? oldColumn;
  final ColumnDefAst? column;
  final Map<String, Object?>? options;
  AlterTableStmt(this.table, this.action,
      {this.newName, this.oldColumn, this.column, this.options});
}

class TxnStmt extends Stmt {
  final String kind; // BEGIN, COMMIT, ROLLBACK, SAVEPOINT, RELEASE, ROLLBACK TO
  final String? savepoint;
  TxnStmt(this.kind, [this.savepoint]);
}

class PragmaStmt extends Stmt {
  final String name;
  final Object? value; // literal or identifier text
  final bool call; // PRAGMA x(y) vs x = y
  PragmaStmt(this.name, this.value, this.call);
}

class ExplainStmt extends Stmt {
  final bool queryPlan;
  final Stmt stmt;
  ExplainStmt(this.queryPlan, this.stmt);
}

/// CREATE KV STORE name [WITH (...)].
class CreateKvStoreStmt extends Stmt {
  final bool ifNotExists;
  final String name;
  final Map<String, Object?> options;
  CreateKvStoreStmt(this.ifNotExists, this.name, this.options);
}

/// CREATE TIMESERIES name (cols) PARTITION BY x RETENTION '...' WITH (...).
class CreateTimeseriesStmt extends Stmt {
  final bool ifNotExists;
  final String name;
  final List<ColumnDefAst> columns;
  final String? partitionBy;
  final String? retention;
  final Map<String, Object?> options;
  CreateTimeseriesStmt(this.ifNotExists, this.name, this.columns,
      this.partitionBy, this.retention, this.options);
}

/// CREATE ROLLUP name [(cols)] [ON series] [EVERY '...'] [RETENTION '...']
/// [WITH (...)] AS select (the clauses may also follow the select).
class CreateRollupStmt extends Stmt {
  final bool ifNotExists;
  final String name;
  final List<String>? columns;
  final SelectStmt select;
  final String? every;
  final String? retention;
  final Map<String, Object?> options;

  /// The series of `ON series` (else the select's FROM names it).
  final String? on;
  CreateRollupStmt(this.ifNotExists, this.name, this.columns, this.select,
      this.every, this.retention, this.options, {this.on});
}

class VacuumStmt extends Stmt {
  final String? mode; // ULTRA or null
  VacuumStmt(this.mode);
}

/// ANALYZE, REINDEX: accepted and ignored.
class NoopStmt extends Stmt {
  final String kind;
  NoopStmt(this.kind);
}
