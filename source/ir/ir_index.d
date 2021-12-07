/**
Copyright: Copyright (c) 2017-2019 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
/// IR Index. Points to any entity in function's IR
module ir.ir_index;

import std.format : formattedWrite;
import std.bitmanip : bitfields;

import all;

/// Represent index of any IR entity inside function's ir array
@(IrValueKind.none)
struct IrIndex
{
	///
	this(uint _storageUintIndex, IrValueKind _kind)
	{
		storageUintIndex = _storageUintIndex;
		kind = _kind;
	}

	/// Constructor for physicalRegister
	this(PhysReg reg, uint regSize)
	{
		physRegIndex = reg.regIndex;
		physRegSize = regSize;
		physRegClass = reg.regClass;
		kind = IrValueKind.physicalRegister;
	}

	/// ditto
	this(uint index, uint regSize, uint regClass)
	{
		physRegIndex = index;
		physRegSize = regSize;
		physRegClass = regClass;
		kind = IrValueKind.physicalRegister;
	}

	// Create from uint representation
	static IrIndex fromUint(uint data)
	{
		IrIndex res;
		res.asUint = data;
		return res;
	}

	union
	{
		mixin(bitfields!(
			uint,        "storageUintIndex", 28, // may be 0 for defined index
			IrValueKind, "kind",              4  // is never 0 for defined index
		));

		// used when kind == IrValueKind.constant
		mixin(bitfields!(
			// Big constants use constantIndex as index into IrConstantStorage
			// Small constants store data directly in constantIndex.
			uint,            "constantIndex", 24,
			IrArgSize,       "constantSize",   2,
			// kind of constant
			IrConstantKind,  "constantKind",   2,
			IrValueKind,     "",               4  // index kind
		));

		enum TYPE_INDEX_BITS = 24;

		// used when kind == IrValueKind.type || kind == IrValueKind.constantZero
		// types are stored in 8-byte chunked buffer
		mixin(bitfields!(
			// if typeKind is basic, then typeIndex contains IrBasicType
			uint,        "typeIndex", TYPE_INDEX_BITS, // may be 0 for defined index
			IrTypeKind,  "typeKind",                4, // type kind
			IrValueKind, "",                        4  // index kind
		));

		// used when kind == IrValueKind.physicalRegister
		mixin(bitfields!(
			// machine-specific index
			uint,        "physRegIndex",     12,
			// physical register size
			// Not in bytes, but a machine-specific enum value
			uint,        "physRegSize",       8,
			// physical register class
			uint,        "physRegClass",      8,
			IrValueKind, "",                  4  // index `kind`
		));

		// is 0 for undefined index
		uint asUint;
	}
	static assert(IrValueKind.max <= 0b1111, "4 bits are reserved for IrValueKind");

	bool isDefined() const { return asUint != 0; }
	bool isUndefined() const { return asUint == 0; }

	void toString(scope void delegate(const(char)[]) sink) const {
		if (asUint == 0) {
			sink("<null>");
			return;
		}

		switch(kind) with(IrValueKind) {
			default: sink.formattedWrite("0x%X", asUint); break;
			case array: sink.formattedWrite("arr%s", storageUintIndex); break;
			case instruction: sink.formattedWrite("i.%s", storageUintIndex); break;
			case basicBlock: sink.formattedWrite("@%s", storageUintIndex); break;
			case constant:
				final switch(constantKind) with(IrConstantKind) {
					case smallZx: sink.formattedWrite("%s", constantIndex); break;
					case smallSx: sink.formattedWrite("%s", (cast(int)constantIndex << 8) >> 8); break;
					case big: sink.formattedWrite("cu.%s", constantIndex); break;
				}
				break;

			case constantAggregate: sink.formattedWrite("caggr.%s", storageUintIndex); break;
			case constantZero:
				if (typeKind == IrTypeKind.basic)
					sink("0");
				else
					sink("zeroinit");
				break;

			case global: sink.formattedWrite("g%s", storageUintIndex); break;
			case phi: sink.formattedWrite("phi%s", storageUintIndex); break;
			case stackSlot: sink.formattedWrite("s%s", storageUintIndex); break;
			case virtualRegister: sink.formattedWrite("v%s", storageUintIndex); break;
			case physicalRegister: sink.formattedWrite("r%s<c%s s%s>", physRegIndex, physRegClass, physRegSize); break;
			case type: sink.formattedWrite("type.%s.%s", typeKind, typeIndex); break;
			case variable: sink.formattedWrite("var%s", storageUintIndex); break;
			case func: sink.formattedWrite("f%s", storageUintIndex); break;
		}
	}

	/// When this index represents index of 0's array item, produces
	/// index of this array items. Calling with 0 returns itself.
	IrIndex indexOf(T)(size_t offset)
	{
		static assert(T.alignof == 4, "Can only point to types aligned to 4 bytes");
		IrIndex result = this;
		result.storageUintIndex = cast(uint)(storageUintIndex + divCeil(T.sizeof, uint.sizeof) * offset);
		return result;
	}

	const:

	bool isInstruction() { return kind == IrValueKind.instruction; }
	bool isBasicBlock() { return kind == IrValueKind.basicBlock; }
	bool isPhi() { return kind == IrValueKind.phi; }
	bool isConstant() { return kind == IrValueKind.constant; }
	bool isSimpleConstant() { return kind == IrValueKind.constant || kind == IrValueKind.constantZero; }
	bool isConstantAggregate() { return kind == IrValueKind.constantAggregate; }
	bool isConstantZero() { return kind == IrValueKind.constantZero; }
	bool isSomeConstant() { return
			kind == IrValueKind.constant ||
			kind == IrValueKind.constantAggregate ||
			kind == IrValueKind.constantZero; }
	bool isGlobal() { return kind == IrValueKind.global; }
	bool isVirtReg() { return kind == IrValueKind.virtualRegister; }
	bool isPhysReg() { return kind == IrValueKind.physicalRegister; }
	bool isSomeReg() {
		return kind == IrValueKind.virtualRegister ||
			kind == IrValueKind.physicalRegister;
	}
	bool isStackSlot() { return kind == IrValueKind.stackSlot; }
	bool isType() { return kind == IrValueKind.type; }
	bool isVariable() { return kind == IrValueKind.variable; }
	bool isFunction() { return kind == IrValueKind.func; }

	bool isTypeBasic() { return kind == IrValueKind.type && typeKind == IrTypeKind.basic; }
	bool isTypePointer() { return kind == IrValueKind.type && typeKind == IrTypeKind.pointer; }
	bool isTypeArray() { return kind == IrValueKind.type && typeKind == IrTypeKind.array; }
	bool isTypeStruct() { return kind == IrValueKind.type && typeKind == IrTypeKind.struct_t; }
	bool isTypeAggregate() {
		return kind == IrValueKind.type &&
			(typeKind == IrTypeKind.struct_t || typeKind == IrTypeKind.array);
	}
	bool isTypeFunction() { return kind == IrValueKind.type && typeKind == IrTypeKind.func_t; }
	bool isTypeVoid() {
		return kind == IrValueKind.type && typeKind == IrTypeKind.basic && typeIndex == IrBasicType.void_t;
	}
	bool isTypeNoreturn() {
		return kind == IrValueKind.type && typeKind == IrTypeKind.basic && typeIndex == IrBasicType.noreturn_t;
	}
	bool isTypeFloat() {
		return kind == IrValueKind.type && typeKind == IrTypeKind.basic && (typeIndex == IrBasicType.f32 || typeIndex == IrBasicType.f64);
	}
	bool isTypeInteger() {
		return kind == IrValueKind.type && typeKind == IrTypeKind.basic && (typeIndex >= IrBasicType.i8 && typeIndex <= IrBasicType.i64);
	}
	IrBasicType basicType(CompilationContext* c) {
		c.assertf(kind == IrValueKind.type, "%s != IrValueKind.type", kind);
		c.assertf(typeKind == IrTypeKind.basic, "%s != IrTypeKind.basic", typeKind);
		return cast(IrBasicType)typeIndex;
	}

	IrIndex typeOfConstantZero() {
		assert(isConstantZero);
		IrIndex copy = this;
		copy.kind = IrValueKind.type;
		return copy;
	}

	IrIndex zeroConstantOfType() {
		assert(isType);
		IrIndex copy = this;
		copy.kind = IrValueKind.constantZero;
		return copy;
	}
}

// compares physical registers size agnostically
// if not physical register compares as usual
bool sameIndexOrPhysReg(IrIndex a, IrIndex b) pure @nogc
{
	if (a.asUint == b.asUint) return true;
	if (a.kind == IrValueKind.physicalRegister)
	{
		a.physRegSize = 0;
		b.physRegSize = 0;
		return a.asUint == b.asUint;
	}
	return false;
}
