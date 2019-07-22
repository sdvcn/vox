/**
Copyright: Copyright (c) 2017-2019 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module fe.ast.statement;

import all;

struct IfStmtNode {
	mixin AstNodeData!(AstType.stmt_if, AstFlags.isStatement);
	ExpressionNode* condition;
	AstNode* thenStatement;
	AstNode* elseStatement; // Nullable
	Scope* then_scope;
	Scope* else_scope;
}

struct WhileStmtNode {
	mixin AstNodeData!(AstType.stmt_while, AstFlags.isStatement);
	ExpressionNode* condition;
	AstNode* statement;
	Scope* _scope;
}

struct DoWhileStmtNode {
	mixin AstNodeData!(AstType.stmt_do_while, AstFlags.isStatement);
	ExpressionNode* condition;
	AstNode* statement;
	Scope* _scope;
}

struct ForStmtNode {
	mixin AstNodeData!(AstType.stmt_for, AstFlags.isStatement);
	Array!(AstNode*) init_statements;
	ExpressionNode* condition; // Nullable
	Array!(AstNode*) increment_statements;
	AstNode* statement;
	Scope* _scope;
}

struct ReturnStmtNode {
	mixin AstNodeData!(AstType.stmt_return, AstFlags.isStatement);
	ExpressionNode* expression; // Nullable
}

struct BreakStmtNode {
	mixin AstNodeData!(AstType.stmt_break, AstFlags.isStatement, AstNodeState.name_resolve);
}

struct ContinueStmtNode {
	mixin AstNodeData!(AstType.stmt_continue, AstFlags.isStatement, AstNodeState.name_resolve);
}

struct BlockStmtNode {
	mixin AstNodeData!(AstType.stmt_block, AstFlags.isStatement);
	/// Each node can be expression, declaration or expression
	Array!(AstNode*) statements;
	Scope* _scope;
}
