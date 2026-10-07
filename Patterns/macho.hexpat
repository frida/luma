import std.core;
import std.mem;
import std.string;

MachO macho @ 0x00;

struct MachO {
    std::core::set_endian(std::mem::Endian::Little);
    match (std::mem::read_unsigned($, 4)) {
        (Magic::Universal | Magic::Universal64): UniversalBinary universal [[inline]];
        (_): Image image [[inline]];
    }
};

enum Magic : u32 {
    MachO32 = 0xfeedface,
    MachO64 = 0xfeedfacf,
    MachO32BigEndian = 0xcefaedfe,
    MachO64BigEndian = 0xcffaedfe,
    Universal = 0xbebafeca,
    Universal64 = 0xbfbafeca,
};

struct UniversalBinary {
    Magic magic;
    be u32 nfat_arch;
    match (magic) {
        (Magic::Universal): FatArch<u32> architectures[nfat_arch];
        (Magic::Universal64): FatArch<u64> architectures[nfat_arch];
    }
};

struct FatArch<T> {
    std::core::set_endian(std::mem::Endian::Big);
    CpuType cputype;
    u32 cpusubtype;
    T offset;
    T size;
    u32 align [[format("formatAlignment")]];
    if (sizeof(T) == 8) {
        u32 reserved;
    }
    Image image @ offset;
    str summary = std::format("{} at {:#x} ({} bytes)", std::core::formatted_value(image), offset, size);
} [[format("summaryOf")]];

struct Image {
    MachHeader header;
    match (header.magic) {
        (Magic::MachO64 | Magic::MachO64BigEndian): LoadCommand<u64> commands[header.ncmds];
        (_): LoadCommand<u32> commands[header.ncmds];
    }
    str summary = std::core::formatted_value(header);
} [[format("summaryOf")]];

struct MachHeader {
    std::core::set_endian(std::mem::Endian::Little);
    Magic magic;
    std::core::set_endian(byteOrderOf(magic));
    CpuType cputype;
    CpuSubtype cpusubtype;
    FileType filetype;
    u32 ncmds;
    u32 sizeofcmds;
    HeaderFlags flags;
    if (magic == Magic::MachO64 || magic == Magic::MachO64BigEndian) {
        u32 reserved;
    }
    str summary = std::format("{} {} {}", enumName(std::format("{}", filetype)), enumName(std::format("{}", cputype)),
        std::core::formatted_value(cpusubtype));
} [[format("summaryOf")]];

fn byteOrderOf(Magic magic) {
    if (magic == Magic::MachO32BigEndian || magic == Magic::MachO64BigEndian) {
        return std::mem::Endian::Big;
    }
    return std::mem::Endian::Little;
};

enum CpuType : s32 {
    Any = -1,
    Vax = 1,
    MC680x0 = 6,
    X86 = 7,
    X86_64 = 7 | 0x01000000,
    MC98000 = 10,
    HPPA = 11,
    Arm = 12,
    Arm64 = 12 | 0x01000000,
    Arm64_32 = 12 | 0x02000000,
    MC88000 = 13,
    Sparc = 14,
    I860 = 15,
    PowerPC = 18,
    PowerPC64 = 18 | 0x01000000,
};

struct CpuSubtype {
    match (parent.cputype) {
        (CpuType::X86): X86Subtype x86;
        (CpuType::X86_64): X86_64Subtype x86_64;
        (CpuType::Arm): ArmSubtype arm;
        (CpuType::Arm64): Arm64Subtype arm64;
        (CpuType::Arm64_32): Arm64_32Subtype arm64_32;
        (CpuType::PowerPC | CpuType::PowerPC64): PowerPCSubtype powerpc;
        (_): GenericSubtype generic;
    }
    match (parent.cputype) {
        (CpuType::X86): str summary = enumName(std::format("{}", x86.kind));
        (CpuType::X86_64): str summary = enumName(std::format("{}", x86_64.kind));
        (CpuType::Arm): str summary = enumName(std::format("{}", arm.kind));
        (CpuType::Arm64): str summary = enumName(std::format("{}", arm64.kind));
        (CpuType::Arm64_32): str summary = enumName(std::format("{}", arm64_32.kind));
        (CpuType::PowerPC | CpuType::PowerPC64): str summary = enumName(std::format("{}", powerpc.kind));
        (_): str summary = std::format("{}", generic.kind);
    }
} [[format("summaryOf")]];

bitfield X86Subtype {
    X86SubtypeKind kind : 24;
    padding : 7;
    bool lib64 : 1;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

enum X86SubtypeKind : u32 {
    I386All = 3,
    I486 = 4,
    I486SX = 4 + (8 << 4),
    Pentium = 5,
    PentiumPro = 6 + (1 << 4),
    PentiumIIM3 = 6 + (3 << 4),
    PentiumIIM5 = 6 + (5 << 4),
    Celeron = 7 + (6 << 4),
    CeleronMobile = 7 + (7 << 4),
    Pentium3 = 8,
    Pentium3M = 8 + (1 << 4),
    Pentium3Xeon = 8 + (2 << 4),
    PentiumM = 9,
    Pentium4 = 10,
    Pentium4M = 10 + (1 << 4),
    Itanium = 11,
    Itanium2 = 11 + (1 << 4),
    Xeon = 12,
    XeonMP = 12 + (1 << 4),
};

bitfield X86_64Subtype {
    X86_64SubtypeKind kind : 24;
    padding : 7;
    bool lib64 : 1;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

enum X86_64SubtypeKind : u32 {
    All = 3,
    Arch1 = 4,
    Haswell = 8,
};

bitfield ArmSubtype {
    ArmSubtypeKind kind : 24;
    padding : 8;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

enum ArmSubtypeKind : u32 {
    All = 0,
    V4T = 5,
    V6 = 6,
    V5TEJ = 7,
    XScale = 8,
    V7 = 9,
    V7F = 10,
    V7S = 11,
    V7K = 12,
    V8 = 13,
    V6M = 14,
    V7M = 15,
    V7EM = 16,
    V8M = 17,
    V8MBase = 18,
    V8_1MMain = 19,
};

bitfield Arm64Subtype {
    Arm64SubtypeKind kind : 24;
    padding : 7;
    bool ptrauthAbi : 1;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

enum Arm64SubtypeKind : u32 {
    All = 0,
    V8 = 1,
    E = 2,
    X1 = 3,
    EX1 = 12,
};

bitfield Arm64_32Subtype {
    Arm64_32SubtypeKind kind : 24;
    padding : 8;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

enum Arm64_32SubtypeKind : u32 {
    All = 0,
    V8 = 1,
};

bitfield PowerPCSubtype {
    PowerPCSubtypeKind kind : 24;
    padding : 8;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

enum PowerPCSubtypeKind : u32 {
    All = 0,
    P601 = 1,
    P602 = 2,
    P603 = 3,
    P603e = 4,
    P603ev = 5,
    P604 = 6,
    P604e = 7,
    P620 = 8,
    P750 = 9,
    P7400 = 10,
    P7450 = 11,
    P970 = 100,
};

bitfield GenericSubtype {
    u32 kind : 24;
    u8 capabilities : 8;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

enum FileType : u32 {
    Object = 0x1,
    Execute = 0x2,
    Fvmlib = 0x3,
    Core = 0x4,
    Preload = 0x5,
    Dylib = 0x6,
    Dylinker = 0x7,
    Bundle = 0x8,
    DylibStub = 0x9,
    Dsym = 0xa,
    KextBundle = 0xb,
    Fileset = 0xc,
    GpuExecute = 0xd,
    GpuDylib = 0xe,
};

bitfield HeaderFlags {
    bool noundefs : 1;
    bool incrlink : 1;
    bool dyldlink : 1;
    bool bindatload : 1;
    bool prebound : 1;
    bool split_segs : 1;
    bool lazy_init : 1;
    bool twolevel : 1;
    bool force_flat : 1;
    bool nomultidefs : 1;
    bool nofixprebinding : 1;
    bool prebindable : 1;
    bool allmodsbound : 1;
    bool subsections_via_symbols : 1;
    bool canonical : 1;
    bool weak_defines : 1;
    bool binds_to_weak : 1;
    bool allow_stack_execution : 1;
    bool root_safe : 1;
    bool setuid_safe : 1;
    bool no_reexported_dylibs : 1;
    bool pie : 1;
    bool dead_strippable_dylib : 1;
    bool has_tlv_descriptors : 1;
    bool no_heap_execution : 1;
    bool app_extension_safe : 1;
    bool nlist_outofsync_with_dyldinfo : 1;
    bool sim_support : 1;
    bool implicit_pagezero : 1;
    padding : 2;
    bool dylib_in_cache : 1;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

struct LoadCommand<Addr> {
    u64 imageStart = addressof(parent);
    CpuType cputype = parent.header.cputype;
    LoadCommandType cmd;
    u32 cmdsize;
    match (cmd) {
        (LoadCommandType::Segment): SegmentCommand<u32> payload;
        (LoadCommandType::Symtab): SymtabCommand<Addr> payload;
        (LoadCommandType::Symseg): SymsegCommand payload;
        (LoadCommandType::Thread | LoadCommandType::UnixThread): ThreadCommand payload;
        (LoadCommandType::LoadFvmlib | LoadCommandType::IdFvmlib): FvmlibCommand payload;
        (LoadCommandType::Ident): IdentCommand payload;
        (LoadCommandType::Fvmfile): FvmfileCommand payload;
        (LoadCommandType::Dysymtab): DysymtabCommand<Addr> payload;
        (LoadCommandType::LoadDylib | LoadCommandType::IdDylib | LoadCommandType::LoadWeakDylib | LoadCommandType::ReexportDylib
            | LoadCommandType::LazyLoadDylib | LoadCommandType::LoadUpwardDylib): DylibCommand payload;
        (LoadCommandType::LoadDylinker | LoadCommandType::IdDylinker | LoadCommandType::DyldEnvironment): DylinkerCommand payload;
        (LoadCommandType::PreboundDylib): PreboundDylibCommand payload;
        (LoadCommandType::Routines): RoutinesCommand<u32> payload;
        (LoadCommandType::SubFramework): SubFrameworkCommand payload;
        (LoadCommandType::SubUmbrella): SubUmbrellaCommand payload;
        (LoadCommandType::SubClient): SubClientCommand payload;
        (LoadCommandType::SubLibrary): SubLibraryCommand payload;
        (LoadCommandType::TwolevelHints): TwolevelHintsCommand payload;
        (LoadCommandType::PrebindCksum): PrebindCksumCommand payload;
        (LoadCommandType::Segment64): SegmentCommand<u64> payload;
        (LoadCommandType::Routines64): RoutinesCommand<u64> payload;
        (LoadCommandType::Uuid): UuidCommand payload;
        (LoadCommandType::Rpath): RpathCommand payload;
        (LoadCommandType::CodeSignature): CodeSignatureCommand payload;
        (LoadCommandType::SegmentSplitInfo): SegmentSplitInfoCommand payload;
        (LoadCommandType::EncryptionInfo): EncryptionInfoCommand payload;
        (LoadCommandType::DyldInfo | LoadCommandType::DyldInfoOnly): DyldInfoCommand payload;
        (LoadCommandType::VersionMinMacOSX | LoadCommandType::VersionMinIPhoneOS | LoadCommandType::VersionMinTvOS
            | LoadCommandType::VersionMinWatchOS): VersionMinCommand payload;
        (LoadCommandType::FunctionStarts): FunctionStartsCommand payload;
        (LoadCommandType::Main): EntryPointCommand payload;
        (LoadCommandType::DataInCode): DataInCodeCommand payload;
        (LoadCommandType::SourceVersion): SourceVersionCommand payload;
        (LoadCommandType::DylibCodeSignDrs): DylibCodeSignDrsCommand payload;
        (LoadCommandType::EncryptionInfo64): EncryptionInfoCommand64 payload;
        (LoadCommandType::LinkerOption): LinkerOptionCommand payload;
        (LoadCommandType::LinkerOptimizationHint): LinkerOptimizationHintCommand payload;
        (LoadCommandType::Note): NoteCommand payload;
        (LoadCommandType::BuildVersion): BuildVersionCommand payload;
        (LoadCommandType::DyldExportsTrie): ExportsTrieCommand payload;
        (LoadCommandType::DyldChainedFixups): ChainedFixupsCommand payload;
        (LoadCommandType::FilesetEntry): FilesetEntryCommand payload;
        (LoadCommandType::AtomInfo): AtomInfoCommand payload;
        (LoadCommandType::FunctionVariants): FunctionVariantsCommand payload;
        (LoadCommandType::FunctionVariantFixups): FunctionVariantFixupsCommand payload;
        (LoadCommandType::TargetTriple): TargetTripleCommand payload;
        (LoadCommandType::LazyLoadDylibInfo): LazyLoadDylibInfoCommand payload;
        (_): OpaqueCommand payload;
    }
    padding[cmdsize - ($ - addressof(this))];
    str commandName = std::string::replace(std::format("{}", cmd), "LoadCommandType::", "");
} [[format("describeLoadCommand")]];

fn describeLoadCommand(ref auto command) {
    return command.commandName + " " + std::core::formatted_value(command.payload);
};

enum LoadCommandType : u32 {
    Segment = 0x1,
    Symtab = 0x2,
    Symseg = 0x3,
    Thread = 0x4,
    UnixThread = 0x5,
    LoadFvmlib = 0x6,
    IdFvmlib = 0x7,
    Ident = 0x8,
    Fvmfile = 0x9,
    Prepage = 0xa,
    Dysymtab = 0xb,
    LoadDylib = 0xc,
    IdDylib = 0xd,
    LoadDylinker = 0xe,
    IdDylinker = 0xf,
    PreboundDylib = 0x10,
    Routines = 0x11,
    SubFramework = 0x12,
    SubUmbrella = 0x13,
    SubClient = 0x14,
    SubLibrary = 0x15,
    TwolevelHints = 0x16,
    PrebindCksum = 0x17,
    LoadWeakDylib = 0x18 | 0x80000000,
    Segment64 = 0x19,
    Routines64 = 0x1a,
    Uuid = 0x1b,
    Rpath = 0x1c | 0x80000000,
    CodeSignature = 0x1d,
    SegmentSplitInfo = 0x1e,
    ReexportDylib = 0x1f | 0x80000000,
    LazyLoadDylib = 0x20,
    EncryptionInfo = 0x21,
    DyldInfo = 0x22,
    DyldInfoOnly = 0x22 | 0x80000000,
    LoadUpwardDylib = 0x23 | 0x80000000,
    VersionMinMacOSX = 0x24,
    VersionMinIPhoneOS = 0x25,
    FunctionStarts = 0x26,
    DyldEnvironment = 0x27,
    Main = 0x28 | 0x80000000,
    DataInCode = 0x29,
    SourceVersion = 0x2a,
    DylibCodeSignDrs = 0x2b,
    EncryptionInfo64 = 0x2c,
    LinkerOption = 0x2d,
    LinkerOptimizationHint = 0x2e,
    VersionMinTvOS = 0x2f,
    VersionMinWatchOS = 0x30,
    Note = 0x31,
    BuildVersion = 0x32,
    DyldExportsTrie = 0x33 | 0x80000000,
    DyldChainedFixups = 0x34 | 0x80000000,
    FilesetEntry = 0x35 | 0x80000000,
    AtomInfo = 0x36,
    FunctionVariants = 0x37,
    FunctionVariantFixups = 0x38,
    TargetTriple = 0x39,
    LazyLoadDylibInfo = 0x3a,
};

struct SegmentCommand<Addr> {
    u64 imageStart = parent.imageStart;
    CpuType cputype = parent.cputype;
    char segname[16];
    Addr vmaddr;
    Addr vmsize;
    Addr fileoff;
    Addr filesize;
    VmProt maxprot;
    VmProt initprot;
    u32 nsects;
    SegmentFlags flags;
    Section<Addr> sections[nsects];
    str summary = std::format("{} {:#x}-{:#x} {}", fixedString(addressof(segname), 16), vmaddr, vmaddr + vmsize,
        std::core::formatted_value(initprot));
} [[format("summaryOf")]];

bitfield VmProt {
    bool read : 1;
    bool write : 1;
    bool execute : 1;
    padding : 29;
} [[format("describeVmProt"), bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

fn describeVmProt(ref auto prot) {
    return (prot.read ? "r" : "-") + (prot.write ? "w" : "-") + (prot.execute ? "x" : "-");
};

bitfield SegmentFlags {
    bool highvm : 1;
    bool fvmlib : 1;
    bool noreloc : 1;
    bool protected_version_1 : 1;
    bool read_only : 1;
    padding : 27;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

struct Section<Addr> {
    u64 imageStart = parent.imageStart;
    CpuType cputype = parent.cputype;
    char sectname[16];
    char segname[16];
    Addr addr;
    Addr size;
    u32 offset;
    u32 align [[format("formatAlignment")]];
    u32 reloff;
    u32 nreloc;
    SectionFlags flags;
    u32 reserved1;
    u32 reserved2;
    if (sizeof(Addr) == 8) {
        u32 reserved3;
    }
    if (nreloc > 0) {
        Relocation relocations[nreloc] @ dataOffsetOf(imageStart, reloff);
    }
    u64 contentsOffset = dataOffsetOf(imageStart, offset);
    match (flags.type) {
        (SectionType::Zerofill | SectionType::GbZerofill | SectionType::ThreadLocalZerofill): padding[0];
        (SectionType::CstringLiterals): CString strings[while($ < contentsOffset + size)] @ contentsOffset;
        (SectionType::FourByteLiterals): u32 literals[size / 4] @ contentsOffset;
        (SectionType::EightByteLiterals): u64 literals[size / 8] @ contentsOffset;
        (SectionType::SixteenByteLiterals): u128 literals[size / 16] @ contentsOffset;
        (SectionType::LiteralPointers | SectionType::NonLazySymbolPointers | SectionType::LazySymbolPointers
            | SectionType::LazyDylibSymbolPointers | SectionType::ModInitFuncPointers | SectionType::ModTermFuncPointers
            | SectionType::ThreadLocalVariablePointers | SectionType::ThreadLocalInitFunctionPointers):
            Addr pointers[size / sizeof(Addr)] @ contentsOffset;
        (SectionType::SymbolStubs): SymbolStub stubs[size / reserved2] @ contentsOffset;
        (SectionType::Interposing): InterposingPair<Addr> pairs[size / (2 * sizeof(Addr))] @ contentsOffset;
        (SectionType::ThreadLocalVariables): TlvDescriptor<Addr> descriptors[size / (3 * sizeof(Addr))] @ contentsOffset;
        (SectionType::InitFuncOffsets): u32 offsets[size / 4] @ contentsOffset;
        (_): SectionContents<Addr> contents @ contentsOffset;
    }
    str summary = std::format("{},{} {:#x}-{:#x} {}", fixedString(addressof(segname), 16), fixedString(addressof(sectname), 16), addr,
        addr + size, std::string::replace(std::format("{}", flags.type), "SectionType::", ""));
} [[format("summaryOf")]];

bitfield SectionFlags {
    SectionType type : 8;
    bool loc_reloc : 1;
    bool ext_reloc : 1;
    bool some_instructions : 1;
    padding : 14;
    bool debug : 1;
    bool self_modifying_code : 1;
    bool live_support : 1;
    bool no_dead_strip : 1;
    bool strip_static_syms : 1;
    bool no_toc : 1;
    bool pure_instructions : 1;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

enum SectionType : u8 {
    Regular = 0x0,
    Zerofill = 0x1,
    CstringLiterals = 0x2,
    FourByteLiterals = 0x3,
    EightByteLiterals = 0x4,
    LiteralPointers = 0x5,
    NonLazySymbolPointers = 0x6,
    LazySymbolPointers = 0x7,
    SymbolStubs = 0x8,
    ModInitFuncPointers = 0x9,
    ModTermFuncPointers = 0xa,
    Coalesced = 0xb,
    GbZerofill = 0xc,
    Interposing = 0xd,
    SixteenByteLiterals = 0xe,
    DtraceDof = 0xf,
    LazyDylibSymbolPointers = 0x10,
    ThreadLocalRegular = 0x11,
    ThreadLocalZerofill = 0x12,
    ThreadLocalVariables = 0x13,
    ThreadLocalVariablePointers = 0x14,
    ThreadLocalInitFunctionPointers = 0x15,
    InitFuncOffsets = 0x16,
};

struct CString {
    char text[];
    str summary = text;
} [[format("summaryOf")]];

struct SymbolStub {
    u8 code[parent.reserved2];
};

struct InterposingPair<Addr> {
    Addr replacement;
    Addr original;
};

struct TlvDescriptor<Addr> {
    Addr thunk;
    Addr key;
    Addr offset;
};

struct SectionContents<Addr> {
    if (std::string::starts_with(parent.sectname, "__objc_imageinfo")) {
        ObjcImageInfo imageinfo;
    } else if (std::string::starts_with(parent.sectname, "__info_plist") || std::string::starts_with(parent.sectname, "__entitlements")
        || std::string::starts_with(parent.sectname, "__launchd_plist")) {
        char text[parent.size];
    } else {
        u8 bytes[parent.size] [[sealed]];
    }
};

struct ObjcImageInfo {
    u32 version;
    ObjcImageInfoFlags flags;
};

bitfield ObjcImageInfoFlags {
    bool is_replacement : 1;
    bool supports_gc : 1;
    bool requires_gc : 1;
    bool optimized_by_dyld : 1;
    bool corrected_synthesize : 1;
    bool is_simulated : 1;
    bool has_category_class_properties : 1;
    bool optimized_by_dyld_closure : 1;
    u8 swift_unstable_version : 8;
    u16 swift_stable_version : 16;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

struct Relocation {
    CpuType cputype = parent.cputype;
    if ((std::mem::read_unsigned($, 4) & 0x80000000) != 0) {
        ScatteredRelocationInfo scattered [[inline]];
    } else {
        RelocationInfo info [[inline]];
    }
};

struct RelocationInfo {
    s32 r_address;
    match (parent.cputype) {
        (CpuType::X86_64): RelocationDescriptor<X86_64RelocationType> descriptor [[inline]];
        (CpuType::Arm64 | CpuType::Arm64_32): RelocationDescriptor<Arm64RelocationType> descriptor [[inline]];
        (CpuType::Arm): RelocationDescriptor<ArmRelocationType> descriptor [[inline]];
        (_): RelocationDescriptor<GenericRelocationType> descriptor [[inline]];
    }
};

bitfield RelocationDescriptor<RelocationType> {
    u32 r_symbolnum : 24;
    bool r_pcrel : 1;
    RelocationLength r_length : 2;
    bool r_extern : 1;
    RelocationType r_type : 4;
};

struct ScatteredRelocationInfo {
    match (parent.cputype) {
        (CpuType::X86_64): ScatteredRelocationDescriptor<X86_64RelocationType> descriptor [[inline]];
        (CpuType::Arm64 | CpuType::Arm64_32): ScatteredRelocationDescriptor<Arm64RelocationType> descriptor [[inline]];
        (CpuType::Arm): ScatteredRelocationDescriptor<ArmRelocationType> descriptor [[inline]];
        (_): ScatteredRelocationDescriptor<GenericRelocationType> descriptor [[inline]];
    }
    s32 r_value;
};

bitfield ScatteredRelocationDescriptor<RelocationType> {
    u32 r_address : 24;
    RelocationType r_type : 4;
    RelocationLength r_length : 2;
    bool r_pcrel : 1;
    bool r_scattered : 1;
};

enum RelocationLength : u8 {
    Byte = 0,
    Word = 1,
    Long = 2,
    Quad = 3,
};

enum GenericRelocationType : u8 {
    Vanilla = 0,
    Pair = 1,
    Sectdiff = 2,
    PbLaPtr = 3,
    LocalSectdiff = 4,
    Tlv = 5,
};

enum X86_64RelocationType : u8 {
    Unsigned = 0,
    Signed = 1,
    Branch = 2,
    GotLoad = 3,
    Got = 4,
    Subtractor = 5,
    Signed1 = 6,
    Signed2 = 7,
    Signed4 = 8,
    Tlv = 9,
};

enum ArmRelocationType : u8 {
    Vanilla = 0,
    Pair = 1,
    Sectdiff = 2,
    LocalSectdiff = 3,
    PbLaPtr = 4,
    Br24 = 5,
    ThumbBr22 = 6,
    Thumb32BitBranch = 7,
    Half = 8,
    HalfSectdiff = 9,
};

enum Arm64RelocationType : u8 {
    Unsigned = 0,
    Subtractor = 1,
    Branch26 = 2,
    Page21 = 3,
    Pageoff12 = 4,
    GotLoadPage21 = 5,
    GotLoadPageoff12 = 6,
    PointerToGot = 7,
    TlvpLoadPage21 = 8,
    TlvpLoadPageoff12 = 9,
    Addend = 10,
    AuthenticatedPointer = 11,
};

struct SymtabCommand<Addr> {
    u32 symoff;
    u32 nsyms;
    u32 stroff;
    u32 strsize;
    u64 stringTable = dataOffsetOf(parent.imageStart, stroff);
    Nlist<Addr> symbols[nsyms] @ dataOffsetOf(parent.imageStart, symoff);
    u8 strings[strsize] @ stringTable [[sealed]];
    str summary = std::format("{} symbols", nsyms);
} [[format("summaryOf")]];

struct Nlist<Addr> {
    u32 n_strx;
    NlistType n_type;
    u8 n_sect;
    if (n_type.isStab) {
        u16 n_desc;
    } else {
        match (n_type.symbol.kind) {
            (SymbolKind::Undefined | SymbolKind::PreboundUndefined): UndefinedSymbolDescription n_desc;
            (_): DefinedSymbolDescription n_desc;
        }
    }
    Addr n_value;
    char name[] @ parent.stringTable + n_strx;
    str summary = name;
} [[format("summaryOf")]];

struct NlistType {
    bool isStab = (std::mem::read_unsigned($, 1) & 0xe0) != 0;
    if (isStab) {
        StabType stab;
        str summary = enumName(std::format("{}", stab));
    } else {
        SymbolType symbol;
        str summary = enumName(std::format("{}", symbol.kind)) + (symbol.external ? " external" : "")
            + (symbol.private_external ? " private" : "");
    }
} [[format("summaryOf")]];

bitfield SymbolType {
    bool external : 1;
    SymbolKind kind : 3;
    bool private_external : 1;
    padding : 3;
};

enum SymbolKind : u8 {
    Undefined = 0x0,
    Absolute = 0x1,
    Indirect = 0x5,
    PreboundUndefined = 0x6,
    Section = 0x7,
};

enum StabType : u8 {
    GSYM = 0x20,
    FNAME = 0x22,
    FUN = 0x24,
    STSYM = 0x26,
    LCSYM = 0x28,
    BNSYM = 0x2e,
    PC = 0x30,
    AST = 0x32,
    OPT = 0x3c,
    RSYM = 0x40,
    SLINE = 0x44,
    ENSYM = 0x4e,
    SSYM = 0x60,
    SO = 0x64,
    OSO = 0x66,
    LIB = 0x68,
    LSYM = 0x80,
    BINCL = 0x82,
    SOL = 0x84,
    PARAMS = 0x86,
    VERSION = 0x88,
    OLEVEL = 0x8a,
    PSYM = 0xa0,
    EINCL = 0xa2,
    ENTRY = 0xa4,
    LBRAC = 0xc0,
    EXCL = 0xc2,
    RBRAC = 0xe0,
    BCOMM = 0xe2,
    ECOMM = 0xe4,
    ECOML = 0xe8,
    LENG = 0xfe,
};

bitfield UndefinedSymbolDescription {
    ReferenceType reference_type : 3;
    padding : 1;
    bool referenced_dynamically : 1;
    bool desc_discarded : 1;
    bool weak_ref : 1;
    bool ref_to_weak : 1;
    u8 library_ordinal : 8 [[format("formatLibraryOrdinal")]];
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 16)]];

bitfield DefinedSymbolDescription {
    ReferenceType reference_type : 3;
    bool arm_thumb_def : 1;
    bool referenced_dynamically : 1;
    bool no_dead_strip : 1;
    bool weak_ref : 1;
    bool weak_def : 1;
    bool symbol_resolver : 1;
    bool alt_entry : 1;
    bool cold_func : 1;
    padding : 5;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 16)]];

enum ReferenceType : u8 {
    UndefinedNonLazy = 0,
    UndefinedLazy = 1,
    Defined = 2,
    PrivateDefined = 3,
    PrivateUndefinedNonLazy = 4,
    PrivateUndefinedLazy = 5,
};

fn formatLibraryOrdinal(u8 ordinal) {
    match (ordinal) {
        (0x00): return "self";
        (0xfe): return "dynamic lookup";
        (0xff): return "executable";
        (_): return std::format("library {}", ordinal);
    }
};

struct SymsegCommand {
    u32 offset;
    u32 size;
    u8 data[size] @ dataOffsetOf(parent.imageStart, offset) [[sealed]];
    str summary = std::format("{} bytes", size);
} [[format("summaryOf")]];

struct ThreadCommand {
    CpuType cputype = parent.cputype;
    u64 end = addressof(parent) + parent.cmdsize;
    match (cputype) {
        (CpuType::Arm | CpuType::Arm64 | CpuType::Arm64_32): ArmThreadState states[while($ < end)];
        (CpuType::X86 | CpuType::X86_64): X86ThreadState states[while($ < end)];
        (_): GenericThreadState states[while($ < end)];
    }
} [[format("describeThreadCommand")]];

fn describeThreadCommand(ref auto command) {
    return std::format("{} states", std::core::member_count(command.states));
};

struct ArmThreadState {
    ArmThreadFlavor flavor;
    u32 count;
    if (parent.cputype == CpuType::Arm64 && flavor == ArmThreadFlavor::ThreadState64) {
        Arm64Registers registers;
    } else if (parent.cputype != CpuType::Arm64 && flavor == ArmThreadFlavor::ThreadState) {
        ArmRegisters registers;
    } else {
        u32 state[count];
    }
    str summary = enumName(std::format("{}", flavor));
} [[format("summaryOf")]];

struct X86ThreadState {
    X86ThreadFlavor flavor;
    u32 count;
    if (parent.cputype == CpuType::X86_64 && flavor == X86ThreadFlavor::ThreadState64) {
        X86_64Registers registers;
    } else if (parent.cputype == CpuType::X86 && flavor == X86ThreadFlavor::ThreadState32) {
        X86Registers registers;
    } else {
        u32 state[count];
    }
    str summary = enumName(std::format("{}", flavor));
} [[format("summaryOf")]];

struct GenericThreadState {
    u32 flavor;
    u32 count;
    u32 state[count];
    str summary = std::format("flavor {}", flavor);
} [[format("summaryOf")]];

enum ArmThreadFlavor : u32 {
    ThreadState = 1,
    VfpState = 2,
    ExceptionState = 3,
    DebugState = 4,
    None = 5,
    ThreadState64 = 6,
    ExceptionState64 = 7,
    ThreadState32 = 9,
    ExceptionState64V2 = 10,
    DebugState32 = 14,
    DebugState64 = 15,
    NeonState = 16,
    NeonState64 = 17,
    CpmuState64 = 18,
    PageinState = 27,
    SmeState = 28,
    SveZState1 = 29,
    SveZState2 = 30,
    SvePState = 31,
    SmeZaState1 = 32,
    SmeZaState2 = 33,
    SmeZaState3 = 34,
    SmeZaState4 = 35,
    SmeZaState5 = 36,
    SmeZaState6 = 37,
    SmeZaState7 = 38,
    SmeZaState8 = 39,
    SmeZaState9 = 40,
    SmeZaState10 = 41,
    SmeZaState11 = 42,
    SmeZaState12 = 43,
    SmeZaState13 = 44,
    SmeZaState14 = 45,
    SmeZaState15 = 46,
    SmeZaState16 = 47,
    Sme2State = 48,
};

enum X86ThreadFlavor : u32 {
    ThreadState32 = 1,
    FloatState32 = 2,
    ExceptionState32 = 3,
    ThreadState64 = 4,
    FloatState64 = 5,
    ExceptionState64 = 6,
    ThreadState = 7,
    FloatState = 8,
    ExceptionState = 9,
    DebugState32 = 10,
    DebugState64 = 11,
    DebugState = 12,
    None = 13,
    AvxState32 = 16,
    AvxState64 = 17,
    AvxState = 18,
    Avx512State32 = 19,
    Avx512State64 = 20,
    Avx512State = 21,
    PageinState = 22,
    ThreadFullState64 = 23,
    InstructionState = 24,
    LastBranchState = 25,
};

struct Arm64Registers {
    u64 x[29];
    u64 fp;
    u64 lr;
    u64 sp;
    u64 pc;
    u32 cpsr;
    u32 pad;
};

struct ArmRegisters {
    u32 r[13];
    u32 sp;
    u32 lr;
    u32 pc;
    u32 cpsr;
};

struct X86_64Registers {
    u64 rax;
    u64 rbx;
    u64 rcx;
    u64 rdx;
    u64 rdi;
    u64 rsi;
    u64 rbp;
    u64 rsp;
    u64 r8;
    u64 r9;
    u64 r10;
    u64 r11;
    u64 r12;
    u64 r13;
    u64 r14;
    u64 r15;
    u64 rip;
    u64 rflags;
    u64 cs;
    u64 fs;
    u64 gs;
};

struct X86Registers {
    u32 eax;
    u32 ebx;
    u32 ecx;
    u32 edx;
    u32 edi;
    u32 esi;
    u32 ebp;
    u32 esp;
    u32 ss;
    u32 eflags;
    u32 eip;
    u32 cs;
    u32 ds;
    u32 es;
    u32 fs;
    u32 gs;
};

struct FvmlibCommand {
    u64 commandStart = addressof(parent);
    Fvmlib fvmlib;
    str summary = fvmlib.name.value;
} [[format("summaryOf")]];

struct Fvmlib {
    u64 commandStart = parent.commandStart;
    LcString name;
    u32 minor_version;
    u32 header_addr;
};

struct IdentCommand {
    std::string::NullString strings[while($ < addressof(parent) + parent.cmdsize)];
    str summary = std::format("{} strings", std::core::member_count(strings));
} [[format("summaryOf")]];

struct FvmfileCommand {
    u64 commandStart = addressof(parent);
    LcString name;
    u32 header_addr;
    str summary = name.value;
} [[format("summaryOf")]];

struct DysymtabCommand<Addr> {
    u64 imageStart = parent.imageStart;
    CpuType cputype = parent.cputype;
    u32 ilocalsym;
    u32 nlocalsym;
    u32 iextdefsym;
    u32 nextdefsym;
    u32 iundefsym;
    u32 nundefsym;
    u32 tocoff;
    u32 ntoc;
    u32 modtaboff;
    u32 nmodtab;
    u32 extrefsymoff;
    u32 nextrefsyms;
    u32 indirectsymoff;
    u32 nindirectsyms;
    u32 extreloff;
    u32 nextrel;
    u32 locreloff;
    u32 nlocrel;
    if (ntoc > 0) {
        DylibTableOfContents toc[ntoc] @ dataOffsetOf(imageStart, tocoff);
    }
    if (nmodtab > 0) {
        DylibModule<Addr> modules[nmodtab] @ dataOffsetOf(imageStart, modtaboff);
    }
    if (nextrefsyms > 0) {
        DylibReference references[nextrefsyms] @ dataOffsetOf(imageStart, extrefsymoff);
    }
    if (nindirectsyms > 0) {
        IndirectSymbol indirect_symbols[nindirectsyms] @ dataOffsetOf(imageStart, indirectsymoff);
    }
    if (nextrel > 0) {
        Relocation external_relocations[nextrel] @ dataOffsetOf(imageStart, extreloff);
    }
    if (nlocrel > 0) {
        Relocation local_relocations[nlocrel] @ dataOffsetOf(imageStart, locreloff);
    }
    str summary = std::format("{} local, {} defined, {} undefined", nlocalsym, nextdefsym, nundefsym);
} [[format("summaryOf")]];

struct DylibTableOfContents {
    u32 symbol_index;
    u32 module_index;
};

struct DylibModule<Addr> {
    u32 module_name;
    u32 iextdefsym;
    u32 nextdefsym;
    u32 irefsym;
    u32 nrefsym;
    u32 ilocalsym;
    u32 nlocalsym;
    u32 iextrel;
    u32 nextrel;
    u32 iinit_iterm;
    u32 ninit_nterm;
    if (sizeof(Addr) == 8) {
        u32 objc_module_info_size;
        u64 objc_module_info_addr;
    } else {
        u32 objc_module_info_addr;
        u32 objc_module_info_size;
    }
};

bitfield DylibReference {
    u32 isym : 24;
    ReferenceType flags : 8;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

struct IndirectSymbol {
    u32 index [[format("formatIndirectSymbol")]];
    str summary = formatIndirectSymbol(index);
} [[format("summaryOf")]];

fn formatIndirectSymbol(u32 index) {
    if ((index & 0x80000000) != 0 && (index & 0x40000000) != 0) {
        return "local absolute";
    }
    if ((index & 0x80000000) != 0) {
        return "local";
    }
    if ((index & 0x40000000) != 0) {
        return "absolute";
    }
    return std::format("symbol {}", index);
};

struct DylibCommand {
    u64 commandStart = addressof(parent);
    LcString name;
    if (name.offset == 28 && std::mem::read_unsigned($, 4) == 0x1a741800) {
        u32 marker;
        Version current_version;
        Version compat_version;
        DylibUseFlags flags;
    } else {
        u32 timestamp [[hex::inline_visualize("timestamp", this)]];
        Version current_version;
        Version compatibility_version;
    }
    str summary = name.value;
} [[format("summaryOf")]];

bitfield DylibUseFlags {
    bool weak_link : 1;
    bool reexport : 1;
    bool upward : 1;
    bool delayed_init : 1;
    padding : 28;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

struct DylinkerCommand {
    u64 commandStart = addressof(parent);
    LcString name;
    str summary = name.value;
} [[format("summaryOf")]];

struct PreboundDylibCommand {
    u64 commandStart = addressof(parent);
    LcString name;
    u32 nmodules;
    LcBitVector<nmodules> linked_modules;
    str summary = std::format("{} ({} modules)", name.value, nmodules);
} [[format("summaryOf")]];

struct RoutinesCommand<Addr> {
    Addr init_address;
    Addr init_module;
    Addr reserved1;
    Addr reserved2;
    Addr reserved3;
    Addr reserved4;
    Addr reserved5;
    Addr reserved6;
    str summary = std::format("init {:#x}", init_address);
} [[format("summaryOf")]];

struct SubFrameworkCommand {
    u64 commandStart = addressof(parent);
    LcString umbrella;
    str summary = umbrella.value;
} [[format("summaryOf")]];

struct SubUmbrellaCommand {
    u64 commandStart = addressof(parent);
    LcString sub_umbrella;
    str summary = sub_umbrella.value;
} [[format("summaryOf")]];

struct SubClientCommand {
    u64 commandStart = addressof(parent);
    LcString client;
    str summary = client.value;
} [[format("summaryOf")]];

struct SubLibraryCommand {
    u64 commandStart = addressof(parent);
    LcString sub_library;
    str summary = sub_library.value;
} [[format("summaryOf")]];

struct TwolevelHintsCommand {
    u32 offset;
    u32 nhints;
    TwolevelHint hints[nhints] @ dataOffsetOf(parent.imageStart, offset);
    str summary = std::format("{} hints", nhints);
} [[format("summaryOf")]];

bitfield TwolevelHint {
    u8 isub_image : 8;
    u32 itoc : 24;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

struct PrebindCksumCommand {
    u32 cksum;
    str summary = std::format("{:#x}", cksum);
} [[format("summaryOf")]];

struct UuidCommand {
    u8 uuid[16] [[format("formatUuid")]];
    str summary = formatUuid(uuid);
} [[format("summaryOf")]];

fn formatUuid(ref auto uuid) {
    return std::format("{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7],
        uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15]);
};

struct RpathCommand {
    u64 commandStart = addressof(parent);
    LcString path;
    str summary = path.value;
} [[format("summaryOf")]];

struct CodeSignatureCommand {
    u32 dataoff;
    u32 datasize;
    SuperBlob signature @ dataOffsetOf(parent.imageStart, dataoff);
    str summary = std::core::formatted_value(signature);
} [[format("summaryOf")]];

struct SuperBlob {
    be BlobMagic magic;
    be u32 length;
    be u32 count;
    BlobIndex index[count];
    str summary = std::format("{} blobs", count);
} [[format("summaryOf")]];

enum BlobMagic : u32 {
    Requirement = 0xfade0c00,
    Requirements = 0xfade0c01,
    CodeDirectory = 0xfade0c02,
    EmbeddedSignature = 0xfade0cc0,
    EmbeddedSignatureOld = 0xfade0b02,
    EmbeddedEntitlements = 0xfade7171,
    EmbeddedDerEntitlements = 0xfade7172,
    DetachedSignature = 0xfade0cc1,
    BlobWrapper = 0xfade0b01,
    EmbeddedLaunchConstraint = 0xfade8181,
};

struct BlobIndex {
    be BlobSlot type;
    be u32 offset;
    Blob blob @ addressof(parent) + offset;
    str summary = enumName(std::format("{}", type));
} [[format("summaryOf")]];

enum BlobSlot : u32 {
    CodeDirectory = 0,
    Info = 1,
    Requirements = 2,
    ResourceDir = 3,
    Application = 4,
    Entitlements = 5,
    DerEntitlements = 7,
    LaunchConstraintSelf = 8,
    LaunchConstraintParent = 9,
    LaunchConstraintResponsible = 10,
    LibraryConstraint = 11,
    AlternateCodeDirectory1 = 0x1000,
    AlternateCodeDirectory2 = 0x1001,
    AlternateCodeDirectory3 = 0x1002,
    AlternateCodeDirectory4 = 0x1003,
    AlternateCodeDirectory5 = 0x1004,
    Signature = 0x10000,
    Identification = 0x10001,
    Ticket = 0x10002,
    Signature2 = 0x10003,
};

struct Blob {
    match (std::mem::read_unsigned($, 4, std::mem::Endian::Big)) {
        (BlobMagic::CodeDirectory): CodeDirectory directory [[inline]];
        (BlobMagic::Requirements): RequirementsBlob requirements [[inline]];
        (BlobMagic::Requirement): RequirementBlob requirement [[inline]];
        (BlobMagic::EmbeddedEntitlements): EntitlementsBlob entitlements [[inline]];
        (_): GenericBlob generic [[inline]];
    }
};

struct CodeDirectory {
    be BlobMagic magic;
    be u32 length;
    be CodeDirectoryVersion version;
    be CodeDirectoryFlags flags;
    be u32 hashOffset;
    be u32 identOffset;
    be u32 nSpecialSlots;
    be u32 nCodeSlots;
    be u32 codeLimit;
    u8 hashSize;
    HashType hashType;
    u8 platform;
    u8 pageSize [[format("formatAlignment")]];
    be u32 spare2;
    if (version >= CodeDirectoryVersion::SupportsScatter) {
        be u32 scatterOffset;
    }
    if (version >= CodeDirectoryVersion::SupportsTeamId) {
        be u32 teamOffset;
    }
    if (version >= CodeDirectoryVersion::SupportsCodeLimit64) {
        be u32 spare3;
        be u64 codeLimit64;
    }
    if (version >= CodeDirectoryVersion::SupportsExecSegment) {
        be u64 execSegBase;
        be u64 execSegLimit;
        be ExecSegmentFlags execSegFlags;
    }
    if (version >= CodeDirectoryVersion::SupportsRuntime) {
        be Version runtime;
        be u32 preEncryptOffset;
    }
    if (version >= CodeDirectoryVersion::SupportsLinkage) {
        HashType linkageHashType;
        u8 linkageApplicationType;
        be u16 linkageApplicationSubType;
        be u32 linkageOffset;
        be u32 linkageSize;
    }
    char identifier[] @ addressof(this) + identOffset;
    if (version >= CodeDirectoryVersion::SupportsTeamId) {
        if (teamOffset != 0) {
            char teamIdentifier[] @ addressof(this) + teamOffset;
        }
    }
    if (version >= CodeDirectoryVersion::SupportsScatter) {
        if (scatterOffset != 0) {
            Scatter scatter[while(std::mem::read_unsigned($, 4, std::mem::Endian::Big) != 0)] @ addressof(this) + scatterOffset;
        }
    }
    SpecialSlots<nSpecialSlots, hashSize> specialSlots @ addressof(this) + hashOffset - nSpecialSlots * hashSize;
    Hash<hashSize> codeSlots[nCodeSlots] @ addressof(this) + hashOffset;
    str summary = std::format("{} {} {} pages", identifier, enumName(std::format("{}", hashType)), nCodeSlots);
} [[format("summaryOf")]];

enum CodeDirectoryVersion : u32 {
    Earliest = 0x20001,
    SupportsScatter = 0x20100,
    SupportsTeamId = 0x20200,
    SupportsCodeLimit64 = 0x20300,
    SupportsExecSegment = 0x20400,
    SupportsRuntime = 0x20500,
    SupportsLinkage = 0x20600,
};

bitfield CodeDirectoryFlags {
    bool valid : 1;
    bool adhoc : 1;
    bool get_task_allow : 1;
    bool installer : 1;
    bool forced_lv : 1;
    bool invalid_allowed : 1;
    padding : 2;
    bool hard : 1;
    bool kill : 1;
    bool check_expiration : 1;
    bool restrict : 1;
    bool enforcement : 1;
    bool require_lv : 1;
    bool entitlements_validated : 1;
    bool nvram_unrestricted : 1;
    bool runtime : 1;
    bool linker_signed : 1;
    padding : 2;
    bool exec_set_hard : 1;
    bool exec_set_kill : 1;
    bool exec_set_enforcement : 1;
    bool exec_inherit_sip : 1;
    bool killed : 1;
    bool no_untrusted_helpers : 1;
    bool platform_binary : 1;
    bool platform_path : 1;
    bool debugged : 1;
    bool signed : 1;
    bool dev_code : 1;
    bool datavault_controller : 1;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

enum HashType : u8 {
    Sha1 = 1,
    Sha256 = 2,
    Sha256Truncated = 3,
    Sha384 = 4,
};

bitfield ExecSegmentFlags {
    bool main_binary : 1;
    padding : 3;
    bool allow_unsigned : 1;
    bool debugger : 1;
    bool jit : 1;
    bool skip_lv : 1;
    bool can_load_cdhash : 1;
    bool can_exec_cdhash : 1;
    padding : 54;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 64)]];

struct Scatter {
    be u32 count;
    be u32 base;
    be u64 targetOffset;
    be u64 spare;
};

struct SpecialSlots<auto Count, auto Size> {
    if (Count >= 11) {
        Hash<Size> libraryConstraint;
    }
    if (Count >= 10) {
        Hash<Size> launchConstraintResponsible;
    }
    if (Count >= 9) {
        Hash<Size> launchConstraintParent;
    }
    if (Count >= 8) {
        Hash<Size> launchConstraintSelf;
    }
    if (Count >= 7) {
        Hash<Size> derEntitlements;
    }
    if (Count >= 6) {
        Hash<Size> slot6;
    }
    if (Count >= 5) {
        Hash<Size> entitlements;
    }
    if (Count >= 4) {
        Hash<Size> application;
    }
    if (Count >= 3) {
        Hash<Size> resourceDirectory;
    }
    if (Count >= 2) {
        Hash<Size> requirements;
    }
    if (Count >= 1) {
        Hash<Size> infoPlist;
    }
};

struct Hash<auto Size> {
    u8 digest[Size] [[sealed]];
};

struct RequirementsBlob {
    be BlobMagic magic;
    be u32 length;
    be u32 count;
    RequirementIndex index[count];
};

struct RequirementIndex {
    be RequirementType type;
    be u32 offset;
    RequirementBlob requirement @ addressof(parent) + offset;
    str summary = enumName(std::format("{}", type));
} [[format("summaryOf")]];

enum RequirementType : u32 {
    Host = 1,
    Guest = 2,
    Designated = 3,
    Library = 4,
    Plugin = 5,
};

struct RequirementBlob {
    be BlobMagic magic;
    be u32 length;
    be RequirementKind kind;
    u8 expression[length - 12] [[sealed]];
};

enum RequirementKind : u32 {
    Expression = 1,
};

struct EntitlementsBlob {
    be BlobMagic magic;
    be u32 length;
    char xml[length - 8];
};

struct GenericBlob {
    be BlobMagic magic;
    be u32 length;
    u8 data[length - 8] [[sealed]];
};

struct SegmentSplitInfoCommand {
    u32 dataoff;
    u32 datasize;
    u8 data[datasize] @ dataOffsetOf(parent.imageStart, dataoff) [[sealed]];
    str summary = std::format("{} bytes", datasize);
} [[format("summaryOf")]];

struct EncryptionInfoCommand {
    u32 cryptoff;
    u32 cryptsize;
    CryptId cryptid;
    str summary = std::format("{} {:#x}-{:#x}", enumName(std::format("{}", cryptid)), cryptoff, cryptoff + cryptsize);
} [[format("summaryOf")]];

struct EncryptionInfoCommand64 {
    u32 cryptoff;
    u32 cryptsize;
    CryptId cryptid;
    u32 pad;
    str summary = std::format("{} {:#x}-{:#x}", enumName(std::format("{}", cryptid)), cryptoff, cryptoff + cryptsize);
} [[format("summaryOf")]];

enum CryptId : u32 {
    None = 0,
    FairPlay = 1,
};

struct DyldInfoCommand {
    u64 imageStart = parent.imageStart;
    u32 rebase_off;
    u32 rebase_size;
    u32 bind_off;
    u32 bind_size;
    u32 weak_bind_off;
    u32 weak_bind_size;
    u32 lazy_bind_off;
    u32 lazy_bind_size;
    u32 export_off;
    u32 export_size;
    if (rebase_size > 0) {
        RebaseOpcodes<rebase_size> rebase @ dataOffsetOf(imageStart, rebase_off);
    }
    if (bind_size > 0) {
        BindOpcodes<bind_size> bind @ dataOffsetOf(imageStart, bind_off);
    }
    if (weak_bind_size > 0) {
        BindOpcodes<weak_bind_size> weak_bind @ dataOffsetOf(imageStart, weak_bind_off);
    }
    if (lazy_bind_size > 0) {
        BindOpcodes<lazy_bind_size> lazy_bind @ dataOffsetOf(imageStart, lazy_bind_off);
    }
    if (export_size > 0) {
        ExportsTrie exports @ dataOffsetOf(imageStart, export_off);
    }
    str summary = std::format("rebase {} bind {} weak {} lazy {} export {} bytes", rebase_size, bind_size, weak_bind_size, lazy_bind_size,
        export_size);
} [[format("summaryOf")]];

struct RebaseOpcodes<auto Size> {
    RebaseInstruction instructions[while($ < addressof(this) + Size)];
};

struct RebaseInstruction {
    RebaseOperation operation;
    match (operation.opcode) {
        (RebaseOpcode::SetSegmentAndOffsetUleb): Uleb128 offset;
        (RebaseOpcode::AddAddrUleb): Uleb128 delta;
        (RebaseOpcode::DoRebaseUlebTimes): Uleb128 count;
        (RebaseOpcode::DoRebaseAddAddrUleb): Uleb128 delta;
        (RebaseOpcode::DoRebaseUlebTimesSkippingUleb): RebaseRun run [[inline]];
        (_): padding[0];
    }
    str opcodeName = std::string::replace(std::format("{}", operation.opcode), "RebaseOpcode::", "");
    str summary = std::format("{} {}", opcodeName, operation.immediate);
} [[format("summaryOf")]];

bitfield RebaseOperation {
    u8 immediate : 4;
    RebaseOpcode opcode : 4;
};

enum RebaseOpcode : u8 {
    Done = 0x0,
    SetTypeImm = 0x1,
    SetSegmentAndOffsetUleb = 0x2,
    AddAddrUleb = 0x3,
    AddAddrImmScaled = 0x4,
    DoRebaseImmTimes = 0x5,
    DoRebaseUlebTimes = 0x6,
    DoRebaseAddAddrUleb = 0x7,
    DoRebaseUlebTimesSkippingUleb = 0x8,
};

struct RebaseRun {
    Uleb128 count;
    Uleb128 skip;
};

struct BindOpcodes<auto Size> {
    BindInstruction instructions[while($ < addressof(this) + Size)];
};

struct BindInstruction {
    BindOperation operation;
    match (operation.opcode) {
        (BindOpcode::SetDylibOrdinalUleb): Uleb128 ordinal;
        (BindOpcode::SetSymbolTrailingFlagsImm): char symbol[];
        (BindOpcode::SetAddendSleb): Sleb128 addend;
        (BindOpcode::SetSegmentAndOffsetUleb): Uleb128 offset;
        (BindOpcode::AddAddrUleb): Uleb128 delta;
        (BindOpcode::DoBindAddAddrUleb): Uleb128 delta;
        (BindOpcode::DoBindUlebTimesSkippingUleb): BindRun run [[inline]];
        (BindOpcode::Threaded): ThreadedBind threaded [[inline]];
        (_): padding[0];
    }
    str opcodeName = std::string::replace(std::format("{}", operation.opcode), "BindOpcode::", "");
    if (operation.opcode == BindOpcode::SetSymbolTrailingFlagsImm) {
        str summary = std::format("{} {}", opcodeName, symbol);
    } else {
        str summary = std::format("{} {}", opcodeName, operation.immediate);
    }
} [[format("summaryOf")]];

bitfield BindOperation {
    u8 immediate : 4;
    BindOpcode opcode : 4;
};

enum BindOpcode : u8 {
    Done = 0x0,
    SetDylibOrdinalImm = 0x1,
    SetDylibOrdinalUleb = 0x2,
    SetDylibSpecialImm = 0x3,
    SetSymbolTrailingFlagsImm = 0x4,
    SetTypeImm = 0x5,
    SetAddendSleb = 0x6,
    SetSegmentAndOffsetUleb = 0x7,
    AddAddrUleb = 0x8,
    DoBind = 0x9,
    DoBindAddAddrUleb = 0xa,
    DoBindAddAddrImmScaled = 0xb,
    DoBindUlebTimesSkippingUleb = 0xc,
    Threaded = 0xd,
};

struct BindRun {
    Uleb128 count;
    Uleb128 skip;
};

struct ThreadedBind {
    if (parent.operation.immediate == ThreadedBindSubopcode::SetBindOrdinalTableSizeUleb) {
        Uleb128 table_size;
    }
};

enum ThreadedBindSubopcode : u8 {
    SetBindOrdinalTableSizeUleb = 0x0,
    Apply = 0x1,
};

struct ExportsTrie {
    ExportNode<addressof(this), ""> root;
};

struct ExportNode<auto TrieStart, auto Prefix> {
    str symbol = Prefix;
    Uleb128 terminalSize;
    if (terminalSize.value != 0) {
        ExportInfo info;
    }
    u8 edgeCount;
    ExportEdge<TrieStart, Prefix> edges[edgeCount];
    if (terminalSize.value != 0) {
        str summary = std::format("{} ({})", symbol, describeExportFlags(info.flags));
    } else {
        str summary = std::format("{} edges", edgeCount);
    }
} [[format("summaryOf")]];

struct ExportInfo {
    Uleb128 flags [[format("describeExportFlags")]];
    if ((flags.value & 0x08) != 0) {
        Uleb128 ordinal;
        char importName[];
    } else if ((flags.value & 0x10) != 0) {
        Uleb128 stub;
        Uleb128 resolver;
    } else {
        Uleb128 address;
    }
};

fn describeExportFlags(ref auto flags) {
    str description = "";
    match (flags.value & 0x03) {
        (0x00): description = "regular";
        (0x01): description = "thread-local";
        (0x02): description = "absolute";
        (_): description = "unknown kind";
    }
    if ((flags.value & 0x04) != 0) {
        description = description + ", weak definition";
    }
    if ((flags.value & 0x08) != 0) {
        description = description + ", reexport";
    }
    if ((flags.value & 0x10) != 0) {
        description = description + ", stub and resolver";
    }
    if ((flags.value & 0x20) != 0) {
        description = description + ", static resolver";
    }
    return description;
};

struct ExportEdge<auto TrieStart, auto Prefix> {
    char label[];
    Uleb128 nodeOffset;
    ExportNode<TrieStart, Prefix + label> node @ TrieStart + nodeOffset.value;
    str summary = label;
} [[format("summaryOf")]];

struct VersionMinCommand {
    Version version;
    Version sdk;
    str summary = std::format("{} (SDK {})", formatVersion(version), formatVersion(sdk));
} [[format("summaryOf")]];

struct FunctionStartsCommand {
    u32 dataoff;
    u32 datasize;
    FunctionStarts<datasize> starts @ dataOffsetOf(parent.imageStart, dataoff);
    str summary = std::format("{} functions", std::core::member_count(starts.deltas));
} [[format("summaryOf")]];

struct FunctionStarts<auto Size> {
    Uleb128 deltas[while($ < addressof(this) + Size && std::mem::read_unsigned($, 1) != 0)];
};

struct EntryPointCommand {
    u64 entryoff;
    u64 stacksize;
    u64 address = virtualAddressOf(parent.imageStart, entryoff);
    str architecture = disassemblerArchitecture(parent.cputype);
    EntryPreview entry @ dataOffsetOf(parent.imageStart, entryoff);
    str summary = std::format("{:#x}", address);
} [[format("summaryOf")]];

struct EntryPreview {
    u8 instructions[64] [[hex::inline_visualize("disassembler", this, parent.address, parent.architecture)]];
};

struct DataInCodeCommand {
    u32 dataoff;
    u32 datasize;
    DataInCodeEntry entries[datasize / 8] @ dataOffsetOf(parent.imageStart, dataoff);
    str summary = std::format("{} entries", datasize / 8);
} [[format("summaryOf")]];

struct DataInCodeEntry {
    u32 offset;
    u16 length;
    DataInCodeKind kind;
};

enum DataInCodeKind : u16 {
    Data = 0x1,
    JumpTable8 = 0x2,
    JumpTable16 = 0x3,
    JumpTable32 = 0x4,
    AbsJumpTable32 = 0x5,
};

struct SourceVersionCommand {
    u64 version [[format("formatSourceVersion")]];
    str summary = formatSourceVersion(version);
} [[format("summaryOf")]];

fn formatSourceVersion(u64 version) {
    return std::format("{}.{}.{}.{}.{}", version >> 40, (version >> 30) & 0x3ff, (version >> 20) & 0x3ff, (version >> 10) & 0x3ff,
        version & 0x3ff);
};

struct DylibCodeSignDrsCommand {
    u32 dataoff;
    u32 datasize;
    Blob requirements @ dataOffsetOf(parent.imageStart, dataoff);
    str summary = std::format("{} bytes", datasize);
} [[format("summaryOf")]];

struct LinkerOptionCommand {
    u32 count;
    std::string::NullString options[count];
    str summary = std::format("{} options", count);
} [[format("summaryOf")]];

struct LinkerOptimizationHintCommand {
    u32 dataoff;
    u32 datasize;
    u8 data[datasize] @ dataOffsetOf(parent.imageStart, dataoff) [[sealed]];
    str summary = std::format("{} bytes", datasize);
} [[format("summaryOf")]];

struct NoteCommand {
    char data_owner[16];
    u64 offset;
    u64 size;
    u8 data[size] @ dataOffsetOf(parent.imageStart, offset) [[sealed]];
    str summary = fixedString(addressof(data_owner), 16);
} [[format("summaryOf")]];

struct BuildVersionCommand {
    Platform platform;
    Version minos;
    Version sdk;
    u32 ntools;
    BuildToolVersion tools[ntools];
    str summary = std::format("{} {} (SDK {})", enumName(std::format("{}", platform)), formatVersion(minos), formatVersion(sdk));
} [[format("summaryOf")]];

enum Platform : u32 {
    Unknown = 0,
    MacOS = 1,
    IOS = 2,
    TvOS = 3,
    WatchOS = 4,
    BridgeOS = 5,
    MacCatalyst = 6,
    IOSSimulator = 7,
    TvOSSimulator = 8,
    WatchOSSimulator = 9,
    DriverKit = 10,
    VisionOS = 11,
    VisionOSSimulator = 12,
    Firmware = 13,
    SepOS = 14,
    MacOSExclaveCore = 15,
    MacOSExclaveKit = 16,
    IOSExclaveCore = 17,
    IOSExclaveKit = 18,
    TvOSExclaveCore = 19,
    TvOSExclaveKit = 20,
    WatchOSExclaveCore = 21,
    WatchOSExclaveKit = 22,
    VisionOSExclaveCore = 23,
    VisionOSExclaveKit = 24,
    Any = 0xffffffff,
};

struct BuildToolVersion {
    Tool tool;
    Version version;
    str summary = std::format("{} {}", enumName(std::format("{}", tool)), formatVersion(version));
} [[format("summaryOf")]];

enum Tool : u32 {
    Clang = 1,
    Swift = 2,
    Ld = 3,
    Lld = 4,
    Metal = 1024,
    AirLld = 1025,
    AirNt = 1026,
    AirNtPlugin = 1027,
    AirPack = 1028,
    GpuArchiver = 1031,
    MetalFramework = 1032,
};

struct ExportsTrieCommand {
    u32 dataoff;
    u32 datasize;
    ExportsTrie exports @ dataOffsetOf(parent.imageStart, dataoff);
    str summary = std::format("{} bytes", datasize);
} [[format("summaryOf")]];

struct ChainedFixupsCommand {
    u32 dataoff;
    u32 datasize;
    ChainedFixups fixups @ dataOffsetOf(parent.imageStart, dataoff);
    str summary = std::core::formatted_value(fixups);
} [[format("summaryOf")]];

struct ChainedFixups {
    ChainedFixupsHeader header;
    ChainedStartsInImage starts @ addressof(this) + header.starts_offset;
    u64 symbols = addressof(this) + header.symbols_offset;
    match (header.imports_format) {
        (ChainedImportFormat::Import): ChainedImport imports[header.imports_count] @ addressof(this) + header.imports_offset;
        (ChainedImportFormat::ImportAddend): ChainedImportAddend imports[header.imports_count] @ addressof(this) + header.imports_offset;
        (ChainedImportFormat::ImportAddend64):
            ChainedImportAddend64 imports[header.imports_count] @ addressof(this) + header.imports_offset;
    }
    str summary = std::format("{} imports", header.imports_count);
} [[format("summaryOf")]];

struct ChainedFixupsHeader {
    u32 fixups_version;
    u32 starts_offset;
    u32 imports_offset;
    u32 symbols_offset;
    u32 imports_count;
    ChainedImportFormat imports_format;
    ChainedSymbolsFormat symbols_format;
};

enum ChainedImportFormat : u32 {
    Import = 1,
    ImportAddend = 2,
    ImportAddend64 = 3,
};

enum ChainedSymbolsFormat : u32 {
    Uncompressed = 0,
    ZlibCompressed = 1,
};

struct ChainedStartsInImage {
    u32 seg_count;
    u32 seg_info_offset[seg_count];
    for (u32 i = 0, i < seg_count, i = i + 1) {
        if (seg_info_offset[i] != 0) {
            ChainedStartsInSegment segment @ addressof(this) + seg_info_offset[i];
        }
    }
};

struct ChainedStartsInSegment {
    u32 size;
    u16 page_size;
    ChainedPointerFormat pointer_format;
    u64 segment_offset;
    u32 max_valid_pointer;
    u16 page_count;
    ChainedPageStart page_start[page_count];
    str summary = std::format("{} at {:#x}, {} pages", enumName(std::format("{}", pointer_format)), segment_offset, page_count);
} [[format("summaryOf")]];

enum ChainedPointerFormat : u16 {
    Arm64e = 1,
    Ptr64 = 2,
    Ptr32 = 3,
    Ptr32Cache = 4,
    Ptr32Firmware = 5,
    Ptr64Offset = 6,
    Arm64eKernel = 7,
    Ptr64KernelCache = 8,
    Arm64eUserland = 9,
    Arm64eFirmware = 10,
    X86_64KernelCache = 11,
    Arm64eUserland24 = 12,
    Arm64eSharedCache = 13,
    Arm64eSegmented = 14,
    Arm64eSharedCacheV3 = 15,
    SharedCacheV2 = 16,
};

struct ChainedPageStart {
    u16 offset [[format("formatChainedPageStart")]];
    str summary = formatChainedPageStart(offset);
} [[format("summaryOf")]];

fn formatChainedPageStart(u16 offset) {
    if (offset == 0xffff) {
        return "no fixups";
    }
    if ((offset & 0x8000) != 0) {
        return std::format("multiple starts at {:#x}", offset & 0x7fff);
    }
    return std::format("{:#x}", offset);
};

struct ChainedImport {
    ChainedImportFields fields;
    char name[] @ parent.symbols + fields.name_offset;
    str summary = std::format("{} ({})", name, formatChainedLibraryOrdinal(fields.lib_ordinal));
} [[format("summaryOf")]];

bitfield ChainedImportFields {
    u8 lib_ordinal : 8 [[format("formatChainedLibraryOrdinal")]];
    bool weak_import : 1;
    u32 name_offset : 23;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

struct ChainedImportAddend {
    ChainedImportFields fields;
    s32 addend;
    char name[] @ parent.symbols + fields.name_offset;
    str summary = std::format("{} ({})", name, formatChainedLibraryOrdinal(fields.lib_ordinal));
} [[format("summaryOf")]];

struct ChainedImportAddend64 {
    ChainedImportAddend64Fields fields;
    u64 addend;
    char name[] @ parent.symbols + fields.name_offset;
    str summary = std::format("{} ({})", name, formatChainedLibraryOrdinal(fields.lib_ordinal));
} [[format("summaryOf")]];

bitfield ChainedImportAddend64Fields {
    u16 lib_ordinal : 16 [[format("formatChainedLibraryOrdinal")]];
    bool weak_import : 1;
    padding : 15;
    u32 name_offset : 32;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 64)]];

fn formatChainedLibraryOrdinal(u16 ordinal) {
    match (ordinal) {
        (0x00): return "self";
        (0xfe | 0xfffe): return "flat lookup";
        (0xfd | 0xfffd): return "weak lookup";
        (0xff | 0xffff): return "main executable";
        (_): return std::format("library {}", ordinal);
    }
};

struct FilesetEntryCommand {
    u64 commandStart = addressof(parent);
    u64 vmaddr;
    u64 fileoff;
    LcString entry_id;
    u32 reserved;
    Image image @ dataOffsetOf(parent.imageStart, fileoff);
    str summary = std::format("{} at {:#x}", entry_id.value, vmaddr);
} [[format("summaryOf")]];

struct AtomInfoCommand {
    u32 dataoff;
    u32 datasize;
    u8 data[datasize] @ dataOffsetOf(parent.imageStart, dataoff) [[sealed]];
    str summary = std::format("{} bytes", datasize);
} [[format("summaryOf")]];

struct FunctionVariantsCommand {
    u32 dataoff;
    u32 datasize;
    u8 data[datasize] @ dataOffsetOf(parent.imageStart, dataoff) [[sealed]];
    str summary = std::format("{} bytes", datasize);
} [[format("summaryOf")]];

struct FunctionVariantFixupsCommand {
    u32 dataoff;
    u32 datasize;
    u8 data[datasize] @ dataOffsetOf(parent.imageStart, dataoff) [[sealed]];
    str summary = std::format("{} bytes", datasize);
} [[format("summaryOf")]];

struct TargetTripleCommand {
    u64 commandStart = addressof(parent);
    LcString triple;
    str summary = triple.value;
} [[format("summaryOf")]];

struct LazyLoadDylibInfoCommand {
    u32 dataoff;
    u32 datasize;
    u8 data[datasize] @ dataOffsetOf(parent.imageStart, dataoff) [[sealed]];
    str summary = std::format("{} bytes", datasize);
} [[format("summaryOf")]];

struct OpaqueCommand {
    u8 data[parent.cmdsize - 8] [[sealed]];
    str summary = std::format("{} bytes", parent.cmdsize - 8);
} [[format("summaryOf")]];

struct LcString {
    u32 offset;
    char value[] @ parent.commandStart + offset;
    str summary = value;
} [[format("summaryOf")]];

struct LcBitVector<auto Count> {
    u32 offset;
    u8 bits[(Count + 7) / 8] @ parent.commandStart + offset;
};

using Version = u32 [[format("formatVersion")]];

fn formatVersion(u32 version) {
    return std::format("{}.{}.{}", version >> 16, (version >> 8) & 0xff, version & 0xff);
};

fn formatAlignment(u32 exponent) {
    return std::format("2^{} ({} bytes)", exponent, 1 << exponent);
};

struct Uleb128 {
    u8 bytes[ulebLength($)] [[hidden]];
    u128 value = ulebValue(addressof(bytes)) [[export]];
    str summary = std::format("{}", value);
} [[format("summaryOf")]];

struct Sleb128 {
    u8 bytes[ulebLength($)] [[hidden]];
    s128 value = slebValue(addressof(bytes)) [[export]];
    str summary = std::format("{}", value);
} [[format("summaryOf")]];

fn summaryOf(ref auto pattern) {
    return pattern.summary;
};

fn enumName(str qualified) {
    u32 start = 0;
    for (u32 i = 1, i < std::string::length(qualified), i = i + 1) {
        if (std::string::at(qualified, i - 1) == ':' && std::string::at(qualified, i) == ':') {
            start = i + 1;
        }
    }
    return std::string::substr(qualified, start, std::string::length(qualified) - start);
};

fn ulebLength(u64 address) {
    u64 length = 1;
    while ((std::mem::read_unsigned(address + length - 1, 1) & 0x80) != 0) {
        length = length + 1;
    }
    return length;
};

fn ulebValue(u64 address) {
    u128 value = 0;
    u32 shift = 0;
    u8 byte = 0x80;
    while ((byte & 0x80) != 0) {
        byte = std::mem::read_unsigned(address, 1);
        value = value | (u128(byte & 0x7f) << shift);
        shift = shift + 7;
        address = address + 1;
    }
    return value;
};

fn slebValue(u64 address) {
    s128 value = 0;
    u32 shift = 0;
    u8 byte = 0x80;
    while ((byte & 0x80) != 0) {
        byte = std::mem::read_unsigned(address, 1);
        value = value | (s128(byte & 0x7f) << shift);
        shift = shift + 7;
        address = address + 1;
    }
    if ((byte & 0x40) != 0) {
        value = value - (s128(1) << shift);
    }
    return value;
};

fn disassemblerArchitecture(CpuType cputype) {
    match (cputype) {
        (CpuType::X86): return "x86";
        (CpuType::X86_64): return "x86_64";
        (CpuType::Arm): return "arm";
        (CpuType::Arm64 | CpuType::Arm64_32): return "arm64";
        (CpuType::PowerPC): return "ppc";
        (CpuType::PowerPC64): return "ppc;64bit";
        (CpuType::Sparc): return "sparc";
        (_): return "";
    }
};

fn fixedString(u64 address, u64 capacity) {
    return std::mem::read_string(address, cstringLength(address, capacity));
};

fn cstringLength(u64 address, u64 capacity) {
    u64 length = 0;
    while (length < capacity && std::mem::read_unsigned(address + length, 1) != 0) {
        length = length + 1;
    }
    return length;
};

fn virtualAddressOf(u64 imageStart, u64 fileOffset) {
    SegmentMapping mapping = segmentContaining(imageStart, fileOffset);
    return mapping.vmaddr + (fileOffset - mapping.fileoff);
};

#ifdef __IMHEX__
fn dataOffsetOf(u64 imageStart, u64 fileOffset) {
    return imageStart + fileOffset;
};
#else
fn dataOffsetOf(u64 imageStart, u64 fileOffset) {
    SegmentMapping mapping = segmentContaining(imageStart, fileOffset);
    SegmentMapping header = segmentContaining(imageStart, 0);
    return imageStart + (mapping.vmaddr - header.vmaddr) + (fileOffset - mapping.fileoff);
};
#endif

struct SegmentMapping {
    u64 vmaddr;
    u64 fileoff;
};

fn segmentContaining(u64 imageStart, u64 fileOffset) {
    SegmentMapping mapping;
    u32 magic = std::mem::read_unsigned(imageStart, 4);
    u32 ncmds = std::mem::read_unsigned(imageStart + 16, 4);
    u64 command = imageStart + ((magic == Magic::MachO64 || magic == Magic::MachO64BigEndian) ? 32 : 28);
    for (u32 i = 0, i < ncmds, i = i + 1) {
        u32 cmd = std::mem::read_unsigned(command, 4);
        if (cmd == LoadCommandType::Segment64) {
            u64 fileoff = std::mem::read_unsigned(command + 40, 8);
            u64 filesize = std::mem::read_unsigned(command + 48, 8);
            if (fileOffset >= fileoff && fileOffset < fileoff + filesize) {
                mapping.vmaddr = std::mem::read_unsigned(command + 24, 8);
                mapping.fileoff = fileoff;
                return mapping;
            }
        } else if (cmd == LoadCommandType::Segment) {
            u32 fileoff = std::mem::read_unsigned(command + 32, 4);
            u32 filesize = std::mem::read_unsigned(command + 36, 4);
            if (fileOffset >= fileoff && fileOffset < fileoff + filesize) {
                mapping.vmaddr = std::mem::read_unsigned(command + 24, 4);
                mapping.fileoff = fileoff;
                return mapping;
            }
        }
        command = command + std::mem::read_unsigned(command + 4, 4);
    }
    return mapping;
};
