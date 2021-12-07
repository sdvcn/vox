/// Copyright: Copyright (c) 2017-2019 Andrey Penechko.
/// License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
/// Authors: Andrey Penechko.

/// Register identifiers in scope tree
module fe.passes.names_register;

import std.stdio;
import std.string : format;
import all;


void pass_names_register(ref CompilationContext context, CompilePassPerModule[] subPasses)
{
	auto state = NameRegisterState(&context);

	foreach (ref SourceFileInfo file; context.files.data) {
		AstIndex modIndex = file.mod.get_ast_index(&context);
		require_name_register(modIndex, state);
		assert(context.analisysStack.length == 0);
	}
}

void require_name_register(ref AstIndex nodeIndex, CompilationContext* context)
{
	auto state = NameRegisterState(context);
	require_name_register(nodeIndex, state);
}

// solves conditional compilation
// must be called inside name_register_nested state
void require_name_register(ref AstNodes items, ref NameRegisterState state)
{
	require_name_register_self_sub_array(items, 0, items.length, state);
	foreach(ref AstIndex item; items) require_name_register(item, state);
}

// returns `items` size delta
// walk all items in from..to range.
// gather all static ifs into linked list, while doing `require_name_register_self`
// for each static if in linked list
//   eval condition
//   in array replace static if node with correct branch
//   call this recursively for inserted subrange
private long require_name_register_self_sub_array(ref AstNodes items, uint from, uint to, ref NameRegisterState state)
{
	CompilationContext* c = state.context;
	state.firstCondDecl = AstIndex();
	state.lastCondDecl = AstIndex();
	size_t i = from;
	foreach(ref AstIndex item; items[from..to]) {
		require_name_register_self(cast(uint)(i++), item, state);
	}

	if (state.firstCondDecl.isUndefined) return 0; // no static ifs

	long sizeDelta;

	AstIndex condDecl = state.firstCondDecl;
	while (condDecl)
	{
		AstNode* decl = condDecl.get_node(c);
		if(decl.astType == AstType.decl_static_foreach)
		{
			auto staticForeachNode = decl.as!StaticForeachDeclNode(c);
			require_name_register(staticForeachNode.iterableExpr, state);
			require_name_resolve(staticForeachNode.iterableExpr, c);

			auto iter = staticForeachNode.iterableExpr.get_node(c);

			if (iter.astType == AstType.decl_alias_array)
			{
				auto aliasArray = iter.as!AliasArrayDeclNode(c);

				size_t bodySize = staticForeachNode.body.length;
				uint numItemsToInsert = cast(uint)(aliasArray.items.length * bodySize);

				uint insertPoint = cast(uint)(staticForeachNode.arrayIndex + sizeDelta);
				items.replaceAtVoid(c.arrayArena, insertPoint, 1, numItemsToInsert);

				foreach(idx, AstIndex item; aliasArray.items)
				{
					// Create scope for key/value vars
					AstIndex instance_scope = c.appendAst!Scope;
					Scope* newScope = c.getAst!Scope(instance_scope);
					newScope.parentScope = staticForeachNode.parentScope;
					newScope.debugName = "#foreach instance";
					newScope.kind = newScope.parentScope.get!Scope(c).kind;

					CloneState cloneState = clone_node(staticForeachNode.body_start, staticForeachNode.after_body, instance_scope, c);

					if (staticForeachNode.keyId.isDefined) {
						AstIndex keyNode = c.appendAst!EnumMemberDecl(staticForeachNode.loc);
						auto enumMemberNode = keyNode.get!EnumMemberDecl(c);
						enumMemberNode.initValue = c.constants.add(makeIrType(IrBasicType.i64), idx);
						enumMemberNode.id = staticForeachNode.keyId;
						enumMemberNode.type = CommonAstNodes.type_u64;
						enumMemberNode.state = AstNodeState.type_check_done;
						newScope.insert(staticForeachNode.keyId, keyNode, c);
					}
					newScope.insert(staticForeachNode.valueId, item, c);

					size_t insertAt = insertPoint + idx * bodySize;
					foreach(j, AstIndex node; staticForeachNode.body)
					{
						cloneState.fixAstIndex(node);
						items[insertAt+j] = node;
					}
				}

				// we replace #foreach with its children
				//   #foreach is removed from the list (-1)
				//   children are inserted (numItemsToInsert)
				sizeDelta += numItemsToInsert - 1;
				sizeDelta += require_name_register_self_sub_array(items, insertPoint, insertPoint+numItemsToInsert, state);
			}
			else
			{
				c.error(iter.loc, "#foreach cannot iterate over %s", iter.astType);
			}

			condDecl = staticForeachNode.next;
		}
		else
		{
			auto condNode = decl.as!ConditionalDeclNode(c);
			AstNodes itemsToInsert;

			if (decl.astType == AstType.decl_static_if)
			{
				auto staticIfNode = condNode.as!StaticIfDeclNode(c);
				require_name_register(staticIfNode.condition, state);
				IrIndex val = eval_static_expr(staticIfNode.condition, c);
				itemsToInsert = c.constants.get(val).i64 ? staticIfNode.thenItems : staticIfNode.elseItems;
			}
			else
			{
				assert(decl.astType == AstType.decl_static_version);
				auto versionNode = condNode.as!StaticVersionDeclNode(c);
				bool isEnabled = false;

				// Is built-in version identifier
				if (versionNode.versionId.index >= commonId_version_id_first && versionNode.versionId.index <= commonId_version_id_last)
				{
					uint versionIndex = versionNode.versionId.index - commonId_version_id_first;
					isEnabled = (c.enabledVersionIdentifiers & (1 << versionIndex)) != 0;
				}
				else
				{
					c.error(decl.loc, "Only built-in versions are supported, not %s", c.idString(versionNode.versionId));
				}

				itemsToInsert = isEnabled ? versionNode.thenItems : versionNode.elseItems;
			}

			uint insertPoint = cast(uint)(condNode.arrayIndex + sizeDelta);
			items.replaceAt(c.arrayArena, insertPoint, 1, itemsToInsert[]);

			// we replace #if with its children
			//   #if is removed from the list (-1)
			//   children are inserted (itemsToInsert.length)
			sizeDelta += itemsToInsert.length - 1;
			sizeDelta += require_name_register_self_sub_array(items, insertPoint, insertPoint+itemsToInsert.length, state);

			condDecl = condNode.next;
		}
	}

	return sizeDelta;
}

// register own identifier in parent scope
void require_name_register_self(uint arrayIndex, ref AstIndex nodeIndex, ref NameRegisterState state)
{
	CompilationContext* c = state.context;
	AstNode* node = c.getAstNode(nodeIndex);

	switch(node.state) with(AstNodeState)
	{
		case name_register_self, name_register_nested, name_resolve, type_check:
			state.context.push_analized_node(AnalysedNode(nodeIndex, CalculatedProperty.name_register_self));
			c.circular_dependency;
		case parse_done:
			// all requirement are done
			break;
		case name_register_self_done, name_register_nested_done, name_resolve_done, type_check_done:
			// already name registered
			return;
		default:
			c.internal_error(node.loc, "Node %s in %s state", node.astType, node.state);
	}

	state.context.push_analized_node(AnalysedNode(nodeIndex, CalculatedProperty.name_register_self));
	scope(success) state.context.pop_analized_node;

	switch(node.astType) with(AstType)
	{
		case error: c.internal_error(node.loc, "Visiting error node");
		case abstract_node: c.internal_error(node.loc, "Visiting abstract node");

		case decl_alias: name_register_self_alias(nodeIndex, cast(AliasDeclNode*)node, state); break;
		case decl_import: name_register_self_import(cast(ImportDeclNode*)node, state); break;
		case decl_function: name_register_self_func(nodeIndex, cast(FunctionDeclNode*)node, state); break;
		case decl_var: name_register_self_var(nodeIndex, cast(VariableDeclNode*)node, state); break;
		case decl_struct: name_register_self_struct(nodeIndex, cast(StructDeclNode*)node, state); break;
		case decl_enum: name_register_self_enum(nodeIndex, cast(EnumDeclaration*)node, state); break;
		case decl_enum_member: name_register_self_enum_member(nodeIndex, cast(EnumMemberDecl*)node, state); break;
		case decl_static_if, decl_static_version, decl_static_foreach:
			auto condDecl = node.as!ConditionalDeclNode(c);
			if (state.lastCondDecl)
				state.lastCondDecl.get!ConditionalDeclNode(c).next = nodeIndex;
			else
				state.firstCondDecl = nodeIndex;
			condDecl.prev = state.lastCondDecl;
			condDecl.arrayIndex = arrayIndex;
			state.lastCondDecl = nodeIndex;
			break;
		case decl_template: name_register_self_template(nodeIndex, cast(TemplateDeclNode*)node, state); break;

		default: c.internal_error(node.loc, "Visiting %s node %s", node.astType, node.state);
	}
}

// register identifiers of nested nodes
void require_name_register(ref AstIndex nodeIndex, ref NameRegisterState state)
{
	AstNode* node = state.context.getAstNode(nodeIndex);

	switch(node.state) with(AstNodeState)
	{
		case name_register_self, name_register_nested, name_resolve, type_check:
			state.context.push_analized_node(AnalysedNode(nodeIndex, CalculatedProperty.name_register_nested));
			state.context.circular_dependency;
		case parse_done:
			auto name_state = NameRegisterState(state.context);
			require_name_register_self(0, nodeIndex, name_state);
			state.context.throwOnErrors;
			goto case;
		case name_register_self_done: break; // all requirement are done
		case name_register_nested_done, name_resolve_done, type_check_done, ir_gen_done: return; // already name registered
		default: state.context.internal_error(node.loc, "Node %s in %s state", node.astType, node.state);
	}

	state.context.push_analized_node(AnalysedNode(nodeIndex, CalculatedProperty.name_register_nested));
	scope(success) state.context.pop_analized_node;

	if (node.hasAttributes) {
		name_register_nested_attributes(node.attributeInfo, state);
	}

	switch(node.astType) with(AstType)
	{
		case error: state.context.internal_error(node.loc, "Visiting error node");
		case abstract_node: state.context.internal_error(node.loc, "Visiting abstract node");

		case decl_alias: assert(false);
		case decl_module: name_register_nested_module(cast(ModuleDeclNode*)node, state); break;
		case decl_import: assert(false);
		case decl_function: name_register_nested_func(nodeIndex, cast(FunctionDeclNode*)node, state); break;
		case decl_var: name_register_nested_var(nodeIndex, cast(VariableDeclNode*)node, state); break;
		case decl_struct: name_register_nested_struct(nodeIndex, cast(StructDeclNode*)node, state); break;
		case decl_enum: name_register_nested_enum(nodeIndex, cast(EnumDeclaration*)node, state); break;
		case decl_enum_member: name_register_nested_enum_member(nodeIndex, cast(EnumMemberDecl*)node, state); break;
		case decl_static_assert: name_register_nested_static_assert(cast(StaticAssertDeclNode*)node, state); break;
		case decl_static_if: assert(false);
		case decl_static_version: assert(false);

		case stmt_block: name_register_nested_block(cast(BlockStmtNode*)node, state); break;
		case stmt_if: name_register_nested_if(cast(IfStmtNode*)node, state); break;
		case stmt_while: name_register_nested_while(cast(WhileStmtNode*)node, state); break;
		case stmt_do_while: name_register_nested_do(cast(DoWhileStmtNode*)node, state); break;
		case stmt_for: name_register_nested_for(cast(ForStmtNode*)node, state); break;
		case stmt_switch: name_register_nested_switch(cast(SwitchStmtNode*)node, state); break;
		case stmt_return: assert(false);
		case stmt_break: assert(false);
		case stmt_continue: assert(false);

		case expr_name_use: assert(false);
		case expr_member: name_register_nested_member(cast(MemberExprNode*)node, state); break;
		case expr_bin_op: name_register_nested_binary_op(cast(BinaryExprNode*)node, state); break;
		case expr_un_op: name_register_nested_unary_op(cast(UnaryExprNode*)node, state); break;
		case expr_call: name_register_nested_call(cast(CallExprNode*)node, state); break;
		case expr_index: name_register_nested_index(cast(IndexExprNode*)node, state); break;
		case expr_slice: name_register_nested_expr_slice(cast(SliceExprNode*)node, state); break;
		case expr_type_conv: name_register_nested_type_conv(cast(TypeConvExprNode*)node, state); break;

		case literal_int: assert(false);
		case literal_float: assert(false);
		case literal_string: assert(false);
		case literal_null: assert(false);
		case literal_bool: assert(false);
		case literal_array: assert(false);

		case type_basic: assert(false);
		case type_func_sig: name_register_nested_func_sig(cast(FunctionSignatureNode*)node, state); break;
		case type_ptr: name_register_nested_ptr(cast(PtrTypeNode*)node, state); break;
		case type_static_array: name_register_nested_static_array(cast(StaticArrayTypeNode*)node, state); break;
		case type_slice: name_register_nested_slice(cast(SliceTypeNode*)node, state); break;

		default: state.context.internal_error(node.loc, "Visiting %s node", node.astType);
	}
}

struct NameRegisterState
{
	CompilationContext* context;

	// first #if or #foreach in a block
	AstIndex firstCondDecl;
	// last #if or #foreach in a block
	AstIndex lastCondDecl;
}
