/**
Copyright: Copyright (c) 2017-2019 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
/// IR Function
module ir.ir_function;

import std.string : format;

import all;
import ir.ir_index;

/// Allows associating a single uint sized item with any object in original IR
/// IR must be immutable (no new items must added)
/// Mirror is stored in temp memory of context
struct IrMirror(T)
{
	static assert(T.sizeof == uint.sizeof, "T size must be equal to uint.sizeof");

	// Mirror of original IR
	private T[] virtRegMirror;
	private T[] basicBlockMirror;
	private T[] phiMirror;
	private T[] instrMirror;

	void createVirtRegMirror(CompilationContext* context, IrFunction* ir) {
		virtRegMirror = makeParallelArray!T(context, ir, ir.numVirtualRegisters);
	}

	void createBasicBlockMirror(CompilationContext* context, IrFunction* ir) {
		basicBlockMirror = makeParallelArray!T(context, ir, ir.numBasicBlocks);
	}

	void createPhiMirror(CompilationContext* context, IrFunction* ir) {
		phiMirror = makeParallelArray!T(context, ir, ir.numPhis);
	}

	void createInstrMirror(CompilationContext* context, IrFunction* ir) {
		instrMirror = makeParallelArray!T(context, ir, ir.numInstructions);
	}

	void createAll(CompilationContext* context, IrFunction* ir)
	{
		createVirtRegMirror(context, ir);
		createBasicBlockMirror(context, ir);
		createPhiMirror(context, ir);
		createInstrMirror(context, ir);
	}

	ref T opIndex(IrIndex index)
	{
		switch (index.kind) with(IrValueKind) {
			case basicBlock: return basicBlockMirror[index.storageUintIndex];
			case phi: return phiMirror[index.storageUintIndex];
			case virtualRegister: return virtRegMirror[index.storageUintIndex];
			case instruction: return instrMirror[index.storageUintIndex];
			default: assert(false, format("%s", index));
		}
	}

	ref T instr(IrIndex index) {
		assert(index.isInstruction);
		return instrMirror[index.storageUintIndex];
	}
	ref T basicBlock(IrIndex index) {
		assert(index.isBasicBlock);
		return basicBlockMirror[index.storageUintIndex];
	}
	ref T phi(IrIndex index) {
		assert(index.isPhi);
		return phiMirror[index.storageUintIndex];
	}
	ref T vreg(IrIndex index) {
		assert(index.isVirtReg);
		return virtRegMirror[index.storageUintIndex];
	}
}

T[] makeParallelArray(T)(CompilationContext* context, IrFunction* ir, uint size)
{
	auto result = cast(T[])context.tempBuffer.voidPut(size);
	result[] = T.init;
	return result;
}

enum IrInstructionSet : ubyte
{
	ir,
	lir_amd64
}
immutable string[] instr_set_names = ["IR", "LIR Amd64"];
static assert(instr_set_names.length == IrInstructionSet.max+1);

immutable InstrInfo[][] allInstrInfos = [
	irInstrInfos,
	amd64InstrInfos
];

struct IrFunction
{
	IrInstrHeader* instrPtr;
	IrIndex* instrPayloadPtr;
	IrIndex* instrNextPtr;
	IrIndex* instrPrevPtr;
	IrPhi* phiPtr;
	uint* arrayPtr;
	IrVirtualRegister* vregPtr;
	// index 0 must be always start block
	// index 1 must be always exit block
	IrBasicBlock* basicBlockPtr;

	/// Used for instrPtr, instrNextPtr, instrPrevPtr
	uint numInstructions;
	uint numPayloadSlots;
	uint numPhis;
	uint arrayLength;
	uint numVirtualRegisters;
	uint numBasicBlocks;

	IrBasicBlock[] blocksArray() {
		return basicBlockPtr[0..numBasicBlocks];
	}

	/// Special block. Automatically created. Program start. Created first.
	enum IrIndex entryBasicBlock = IrIndex(0, IrValueKind.basicBlock);
	/// Special block. Automatically created. All returns must jump to it.
	enum IrIndex exitBasicBlock = IrIndex(1, IrValueKind.basicBlock);

	IrIndex lastBasicBlock() {
		if (numBasicBlocks < 2) return IrIndex();
		return getBlock(exitBasicBlock).prevBlock;
	}

	IrIndex firstVirtReg() {
		if (numVirtualRegisters == 0) return IrIndex();
		return IrIndex(0, IrValueKind.virtualRegister);
	}

	IrIndex lastVirtReg() {
		if (numVirtualRegisters == 0) return IrIndex();
		return IrIndex(numVirtualRegisters - 1, IrValueKind.virtualRegister);
	}

	/// IrTypeFunction index
	IrIndex type;
	///
	IrInstructionSet instructionSet;

	VregIterator virtualRegsiters() { return VregIterator(&this); }

	///
	FunctionBackendData* backendData;


	BlockIterator blocks() { return BlockIterator(&this); }
	BlockReverseIterator blocksReverse() { return BlockReverseIterator(&this); }

	alias getBlock = get!IrBasicBlock;
	alias getPhi = get!IrPhi;
	alias getVirtReg = get!IrVirtualRegister;

	ref T get(T)(IrIndex index)
	{
		enum IrValueKind kind = getIrValueKind!T;
		assert(index.kind != IrValueKind.none, "null index");
		assert(index.kind == kind, format("%s != %s", index.kind, kind));
		static if (kind == IrValueKind.instruction)
			return *cast(T*)(&instrPtr[index.storageUintIndex]);
		else static if (kind == IrValueKind.listItem)
			return *cast(T*)(&arrayPtr[index.storageUintIndex]);
		else static if (kind == IrValueKind.basicBlock)
			return basicBlockPtr[index.storageUintIndex];
		else static if (kind == IrValueKind.phi)
			return phiPtr[index.storageUintIndex];
		else static if (kind == IrValueKind.virtualRegister)
			return vregPtr[index.storageUintIndex];
		else
			static assert(false, format("Cannot get %s from IrFunction", T.stringof));
	}

	// In correct code there must be no dangling basic blocks left
	// But if there were, they would appear after exit block
	void orderBlocks()
	{
		IrIndex first;
		IrIndex firstLink;

		void walk(IrIndex node)
		{
			IrBasicBlock* block = &getBlock(node);
			block.visitFlag = true;
			foreach(ref IrIndex succ; block.successors.range(&this))
				if (!getBlock(succ).visitFlag)
					walk(succ);
			if (first.isDefined)
				linkBlockBefore(&this, node, first);
			else
				firstLink = node;
			first = node;
		}

		walk(entryBasicBlock);

		// bring exit block to the end of function
		if (firstLink != exitBasicBlock)
			linkBlockBefore(&this, firstLink, exitBasicBlock);

		// clear all flags
		foreach (idx, ref IrBasicBlock block; blocks)
		{
			block.visitFlag = false;
		}
	}

	void removeAllPhis() {
		foreach (IrIndex index, ref IrBasicBlock block; blocks)
			block.removeAllPhis;
	}

	void assignSequentialBlockIndices()
	{
		uint index;
		foreach (idx, ref IrBasicBlock block; blocks)
		{
			block.seqIndex = index++;
		}
	}

	IrIndex getValueType(CompilationContext* context, IrIndex someIndex)
	{
		return .getValueType(someIndex, &this, context);
	}

	ref IrIndex prevInstr(IrIndex instrIndex) {
		return instrPrevPtr[instrIndex.storageUintIndex];
	}

	ref IrIndex nextInstr(IrIndex instrIndex) {
		return instrNextPtr[instrIndex.storageUintIndex];
	}

	size_t byteLength() {
		return
			(IrInstrHeader.sizeof + uint.sizeof + uint.sizeof) * numInstructions +
			IrIndex.sizeof * numPayloadSlots +
			IrPhi.sizeof * numPhis +
			uint.sizeof * arrayLength +
			IrVirtualRegister.sizeof * numVirtualRegisters +
			IrBasicBlock.sizeof * numBasicBlocks;
	}
}

void dupIrStorage(IrFunction* ir, CompilationContext* c)
{
	void dupStorage(T)(ref Arena!T arena, ref T* ptr, uint length) {
		//writefln("arena %s %s..%s %s", arena.length, ptr, ptr + length, length);
		T[] buf = ptr[0..length];
		ptr = arena.nextPtr;
		arena.put(buf);
		//writefln("arena %s %s..%s %s", arena.length, ptr, ptr + length, length);
	}

	dupStorage(c.irStorage.instrHeaderBuffer, ir.instrPtr, ir.numInstructions);
	dupStorage(c.irStorage.instrPayloadBuffer, ir.instrPayloadPtr, ir.numPayloadSlots);
	dupStorage(c.irStorage.instrNextBuffer, ir.instrNextPtr, ir.numInstructions);
	dupStorage(c.irStorage.instrPrevBuffer, ir.instrPrevPtr, ir.numInstructions);
	dupStorage(c.irStorage.phiBuffer, ir.phiPtr, ir.numPhis);
	dupStorage(c.irStorage.vregBuffer, ir.vregPtr, ir.numVirtualRegisters);
	dupStorage(c.irStorage.arrayBuffer, ir.arrayPtr, ir.arrayLength);
	dupStorage(c.irStorage.basicBlockBuffer, ir.basicBlockPtr, ir.numBasicBlocks);
}

struct IrFuncStorage
{
	Arena!IrInstrHeader instrHeaderBuffer;
	Arena!IrIndex instrPayloadBuffer; // stores variadic results + arguments per instruction
	Arena!IrIndex instrNextBuffer; // index of next instruction
	Arena!IrIndex instrPrevBuffer; // index of previous instruction
	Arena!IrPhi phiBuffer;
	Arena!IrVirtualRegister vregBuffer;
	Arena!uint arrayBuffer; // stores data of SmallVector
	Arena!IrBasicBlock basicBlockBuffer;

	void printMemSize(ref TextSink sink)
	{
		size_t byteLength;
		size_t committedBytes;
		size_t reservedBytes;
		void collect(T)(ref Arena!T arena) {
			byteLength += arena.byteLength;
			committedBytes += arena.committedBytes;
			reservedBytes += arena.reservedBytes;
		}
		collect(instrHeaderBuffer);
		collect(instrPayloadBuffer);
		collect(instrNextBuffer);
		collect(instrPrevBuffer);
		collect(phiBuffer);
		collect(vregBuffer);
		collect(arrayBuffer);
		collect(basicBlockBuffer);
		sink.putfln("  %-16s%-6iB    %-6iB   %-6iB",
			"  IR total",
			scaledNumberFmt(byteLength),
			scaledNumberFmt(committedBytes),
			scaledNumberFmt(reservedBytes));
	}
}

// instruction iterators are aware of this
// only safe to delete current instruction while iterating
void removeInstruction(IrFunction* ir, IrIndex instrIndex)
{
	if (ir.prevInstr(instrIndex).isInstruction)
		ir.nextInstr(ir.prevInstr(instrIndex)) = ir.nextInstr(instrIndex);
	else if (ir.prevInstr(instrIndex).isBasicBlock)
		ir.getBlock(ir.prevInstr(instrIndex)).firstInstr = ir.nextInstr(instrIndex);
	else assert(false);

	if (ir.nextInstr(instrIndex).isInstruction)
		ir.prevInstr(ir.nextInstr(instrIndex)) = ir.prevInstr(instrIndex);
	else if (ir.nextInstr(instrIndex).isBasicBlock)
		ir.getBlock(ir.nextInstr(instrIndex)).lastInstr = ir.prevInstr(instrIndex);
	else assert(false);
}

void removeUser(CompilationContext* context, IrFunction* ir, IrIndex user, IrIndex used) {
	assert(used.isDefined, "used is undefined");
	final switch (used.kind) with(IrValueKind) {
		case none: assert(false, "removeUser none");
		case listItem: assert(false, "removeUser listItem");
		case instruction: assert(false, "removeUser instruction");
		case basicBlock: break; // allowed. As argument of jmp jcc
		case constant, constantAggregate, constantZero: break; // allowed, noop
		case global:
			context.globals.get(used).removeUser(user);
			break;
		case phi: assert(false, "removeUser phi"); // must be virt reg instead
		case stackSlot: break; // allowed, noop
		case virtualRegister:
			ir.getVirtReg(used).users.remove(ir, user);
			break;
		case physicalRegister: break; // allowed, noop
		case type: break; // no user tracking
		case variable: assert(false);
		case func: break; // allowed, noop
	}
}

struct BlockIterator
{
	IrFunction* ir;
	int opApply(scope int delegate(IrIndex, ref IrBasicBlock) dg) {
		IrIndex next = ir.entryBasicBlock;
		while (next.isDefined)
		{
			IrBasicBlock* block = &ir.getBlock(next);
			if (int res = dg(next, *block))
				return res;
			next = block.nextBlock;
		}
		return 0;
	}
}

struct VregIterator
{
	IrFunction* ir;
	int opApply(scope int delegate(IrIndex, ref IrVirtualRegister) dg) {
		foreach(size_t i, ref IrVirtualRegister vreg; ir.vregPtr[0..ir.numVirtualRegisters])
			if (int res = dg(IrIndex(cast(uint)i, IrValueKind.virtualRegister), vreg))
				return res;
		return 0;
	}
}

struct BlockReverseIterator
{
	IrFunction* ir;
	int opApply(scope int delegate(IrIndex, ref IrBasicBlock) dg) {
		IrIndex prev = ir.exitBasicBlock;
		while (prev.isDefined)
		{
			IrBasicBlock* block = &ir.getBlock(prev);
			if (int res = dg(prev, *block))
				return res;
			prev = block.prevBlock;
		}
		return 0;
	}
}
