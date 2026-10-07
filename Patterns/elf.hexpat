import std.core;
import std.mem;
import std.string;

Elf elf @ 0x00;

struct Elf {
    std::core::set_endian(std::mem::Endian::Little);
    Identification e_ident;
    std::core::set_endian(byteOrderOf(e_ident.ei_data));
    match (e_ident.ei_class) {
        (Class::Elf32): Image<u32> image [[inline]];
        (_): Image<u64> image [[inline]];
    }
};

struct Identification {
    char ei_magic[4];
    Class ei_class;
    Data ei_data;
    u8 ei_version;
    OsAbi ei_osabi;
    u8 ei_abiversion;
    u8 ei_pad[7];
    str summary = std::format("{} {} {}", enumName(std::format("{}", ei_class)), enumName(std::format("{}", ei_data)),
        enumName(std::format("{}", ei_osabi)));
} [[format("summaryOf")]];

fn byteOrderOf(Data data) {
    if (data == Data::BigEndian) {
        return std::mem::Endian::Big;
    }
    return std::mem::Endian::Little;
};

enum Class : u8 {
    None = 0,
    Elf32 = 1,
    Elf64 = 2,
};

enum Data : u8 {
    None = 0,
    LittleEndian = 1,
    BigEndian = 2,
};

enum OsAbi : u8 {
    SystemV = 0,
    HpUx = 1,
    NetBsd = 2,
    Gnu = 3,
    Solaris = 6,
    Aix = 7,
    Irix = 8,
    FreeBsd = 9,
    Tru64 = 10,
    Modesto = 11,
    OpenBsd = 12,
    OpenVms = 13,
    NonStopKernel = 14,
    Aros = 15,
    FenixOs = 16,
    CloudAbi = 17,
    ArmAeabi = 64,
    Arm = 97,
    Standalone = 255,
};

struct Image<Addr> {
    u64 imageStart = addressof(parent);
    FileHeader<Addr> header;
    if (header.e_phoff != 0) {
        u64 programHeaderCount = header.e_phnum == 0xffff ? sectionInfo(imageStart, 0) : header.e_phnum;
        ProgramHeader<Addr> program_headers[programHeaderCount] @ dataOffsetOf(imageStart, header.e_phoff);
    }
    if (header.e_shoff != 0 && fileOffsetIsMapped(imageStart, header.e_shoff)) {
        u64 sectionHeaderCount = header.e_shnum == 0 ? sectionSize(imageStart, 0) : header.e_shnum;
        u64 sectionNamesIndex = header.e_shstrndx == 0xffff ? sectionLink(imageStart, 0) : header.e_shstrndx;
        u64 sectionNames = dataOffsetOf(imageStart, sectionOffset(imageStart, sectionNamesIndex));
        SectionHeader<Addr> section_headers[sectionHeaderCount] @ dataOffsetOf(imageStart, header.e_shoff);
    }
    str summary = std::core::formatted_value(header);
} [[format("summaryOf")]];

struct FileHeader<Addr> {
    ElfType e_type;
    Machine e_machine;
    u32 e_version;
    Addr e_entry;
    Addr e_phoff;
    Addr e_shoff;
    MachineFlags e_flags;
    u16 e_ehsize;
    u16 e_phentsize;
    u16 e_phnum;
    u16 e_shentsize;
    u16 e_shnum;
    u16 e_shstrndx;
    str summary = std::format("{} {} entry {:#x}", enumName(std::format("{}", e_type)), enumName(std::format("{}", e_machine)), e_entry);
} [[format("summaryOf")]];

enum ElfType : u16 {
    None = 0,
    Relocatable = 1,
    Executable = 2,
    SharedObject = 3,
    Core = 4,
    OsSpecific = 0xfe00 ... 0xfeff,
    ProcessorSpecific = 0xff00 ... 0xffff,
};

enum Machine : u16 {
    None = 0,
    M32 = 1,
    Sparc = 2,
    I386 = 3,
    M68K = 4,
    M88K = 5,
    Iamcu = 6,
    I860 = 7,
    Mips = 8,
    S370 = 9,
    MipsRs3Le = 10,
    PaRisc = 15,
    Vpp500 = 17,
    Sparc32Plus = 18,
    I960 = 19,
    Ppc = 20,
    Ppc64 = 21,
    S390 = 22,
    Spu = 23,
    V800 = 36,
    Fr20 = 37,
    Rh32 = 38,
    Rce = 39,
    Arm = 40,
    FakeAlpha = 41,
    Sh = 42,
    SparcV9 = 43,
    TriCore = 44,
    Arc = 45,
    H8_300 = 46,
    H8_300H = 47,
    H8S = 48,
    H8_500 = 49,
    Ia64 = 50,
    MipsX = 51,
    ColdFire = 52,
    M68HC12 = 53,
    Mma = 54,
    Pcp = 55,
    NCpu = 56,
    Ndr1 = 57,
    StarCore = 58,
    Me16 = 59,
    St100 = 60,
    TinyJ = 61,
    X86_64 = 62,
    Pdsp = 63,
    Pdp10 = 64,
    Pdp11 = 65,
    Fx66 = 66,
    St9Plus = 67,
    St7 = 68,
    M68HC16 = 69,
    M68HC11 = 70,
    M68HC08 = 71,
    M68HC05 = 72,
    Svx = 73,
    St19 = 74,
    Vax = 75,
    Cris = 76,
    Javelin = 77,
    FirePath = 78,
    Zsp = 79,
    Mmix = 80,
    Huany = 81,
    Prism = 82,
    Avr = 83,
    Fr30 = 84,
    D10V = 85,
    D30V = 86,
    V850 = 87,
    M32R = 88,
    Mn10300 = 89,
    Mn10200 = 90,
    Pj = 91,
    OpenRisc = 92,
    ArcCompact = 93,
    Xtensa = 94,
    VideoCore = 95,
    TmmGpp = 96,
    Ns32K = 97,
    Tpc = 98,
    Snp1K = 99,
    St200 = 100,
    Ip2K = 101,
    Max = 102,
    Cr = 103,
    F2Mc16 = 104,
    Msp430 = 105,
    Blackfin = 106,
    SeC33 = 107,
    Sep = 108,
    Arca = 109,
    Unicore = 110,
    Excess = 111,
    Dxp = 112,
    AlteraNios2 = 113,
    Crx = 114,
    Xgate = 115,
    C166 = 116,
    M16C = 117,
    DsPic30F = 118,
    Ce = 119,
    M32C = 120,
    Tsk3000 = 131,
    Rs08 = 132,
    Sharc = 133,
    ECog2 = 134,
    Score7 = 135,
    Dsp24 = 136,
    VideoCore3 = 137,
    LatticeMico32 = 138,
    SeC17 = 139,
    TiC6000 = 140,
    TiC2000 = 141,
    TiC5500 = 142,
    TiArp32 = 143,
    TiPru = 144,
    MmdspPlus = 160,
    CypressM8C = 161,
    R32C = 162,
    TriMedia = 163,
    Qdsp6 = 164,
    I8051 = 165,
    Stxp7X = 166,
    Nds32 = 167,
    ECog1X = 168,
    MaxQ30 = 169,
    Ximo16 = 170,
    Manik = 171,
    CrayNv2 = 172,
    Rx = 173,
    Metag = 174,
    McstElbrus = 175,
    ECog16 = 176,
    Cr16 = 177,
    Etpu = 178,
    Sle9X = 179,
    L10M = 180,
    K10M = 181,
    AArch64 = 183,
    Avr32 = 185,
    Stm8 = 186,
    Tile64 = 187,
    TilePro = 188,
    MicroBlaze = 189,
    Cuda = 190,
    TileGx = 191,
    CloudShield = 192,
    CoreA1St = 193,
    CoreA2Nd = 194,
    ArcV2 = 195,
    Open8 = 196,
    Rl78 = 197,
    VideoCore5 = 198,
    R78KOr = 199,
    Dsp56800Ex = 200,
    Ba1 = 201,
    Ba2 = 202,
    XCore = 203,
    MchpPic = 204,
    Km32 = 210,
    Kmx32 = 211,
    Emx16 = 212,
    Emx8 = 213,
    Kvarc = 214,
    Cdp = 215,
    Coge = 216,
    Cool = 217,
    Norc = 218,
    CsrKalimba = 219,
    Z80 = 220,
    Visium = 221,
    Ft32 = 222,
    Moxie = 223,
    AmdGpu = 224,
    RiscV = 243,
    Bpf = 247,
    CSky = 252,
    LoongArch = 258,
    Alpha = 0x9026,
};

struct MachineFlags {
    u32 value;
    str summary = describeMachineFlags(parent.e_machine, value);
} [[format("summaryOf")]];

fn describeMachineFlags(Machine machine, u32 flags) {
    if (machine == Machine::Arm) {
        return describeArmFlags(flags);
    }
    if (machine == Machine::RiscV) {
        return describeRiscVFlags(flags);
    }
    if (machine == Machine::Mips || machine == Machine::MipsRs3Le || machine == Machine::MipsX) {
        return describeMipsFlags(flags);
    }
    return std::format("{:#x}", flags);
};

fn describeArmFlags(u32 flags) {
    str names = std::format(", EABI version {}", flags >> 24);
    names = names + flagName(flags, 0x00800000, "BE8");
    names = names + flagName(flags, 0x00400000, "LE8");
    names = names + flagName(flags, 0x00000001, "relexec");
    names = names + flagName(flags, 0x00000002, "hasentry");
    names = names + flagName(flags, 0x00000004, "interwork");
    names = names + flagName(flags, 0x00000008, "APCS-26");
    names = names + flagName(flags, 0x00000010, "APCS float");
    names = names + flagName(flags, 0x00000020, "PIC");
    names = names + flagName(flags, 0x00000040, "align8");
    names = names + flagName(flags, 0x00000080, "new ABI");
    names = names + flagName(flags, 0x00000100, "old ABI");
    names = names + flagName(flags, 0x00000200, "soft-float ABI");
    names = names + flagName(flags, 0x00000400, "hard-float ABI");
    names = names + flagName(flags, 0x00000800, "Maverick float");
    return flagList(names);
};

fn describeRiscVFlags(u32 flags) {
    str names = "";
    names = names + flagName(flags, 0x0001, "RVC");
    match (flags & 0x0006) {
        (0x0000): names = names + ", soft-float ABI";
        (0x0002): names = names + ", single-float ABI";
        (0x0004): names = names + ", double-float ABI";
        (0x0006): names = names + ", quad-float ABI";
    }
    names = names + flagName(flags, 0x0008, "RVE");
    names = names + flagName(flags, 0x0010, "TSO");
    return flagList(names);
};

fn describeMipsFlags(u32 flags) {
    str names = "";
    match (flags & 0xf0000000) {
        (0x00000000): names = names + ", MIPS I";
        (0x10000000): names = names + ", MIPS II";
        (0x20000000): names = names + ", MIPS III";
        (0x30000000): names = names + ", MIPS IV";
        (0x40000000): names = names + ", MIPS V";
        (0x50000000): names = names + ", MIPS32";
        (0x60000000): names = names + ", MIPS64";
        (0x70000000): names = names + ", MIPS32r2";
        (0x80000000): names = names + ", MIPS64r2";
        (0x90000000): names = names + ", MIPS32r6";
        (0xa0000000): names = names + ", MIPS64r6";
    }
    match (flags & 0x0000f000) {
        (0x00001000): names = names + ", O32";
        (0x00002000): names = names + ", O64";
        (0x00003000): names = names + ", EABI32";
        (0x00004000): names = names + ", EABI64";
    }
    names = names + flagName(flags, 0x00000001, "noreorder");
    names = names + flagName(flags, 0x00000002, "PIC");
    names = names + flagName(flags, 0x00000004, "CPIC");
    names = names + flagName(flags, 0x00000008, "XGOT");
    names = names + flagName(flags, 0x00000010, "64-bit WHIRL");
    names = names + flagName(flags, 0x00000020, "ABI2");
    names = names + flagName(flags, 0x00000040, "ABI on 32");
    names = names + flagName(flags, 0x00000200, "FP64");
    names = names + flagName(flags, 0x00000400, "NaN2008");
    return flagList(names);
};

struct ProgramHeader<Addr> {
    u64 imageStart = parent.imageStart;
    Machine machine = parent.header.e_machine;
    u32 typeValue = std::mem::read_unsigned($, 4);
    SegmentType p_type;
    if (typeValue >= 0x70000000 && typeValue <= 0x7fffffff) {
        if (machine == Machine::Arm) {
            ArmSegmentType arm_type @ addressof(p_type) [[no_unique_address]];
        } else if (machine == Machine::AArch64) {
            AArch64SegmentType aarch64_type @ addressof(p_type) [[no_unique_address]];
        } else if (isMips(machine)) {
            MipsSegmentType mips_type @ addressof(p_type) [[no_unique_address]];
        } else if (machine == Machine::RiscV) {
            RiscVSegmentType riscv_type @ addressof(p_type) [[no_unique_address]];
        }
    }
    if (sizeof(Addr) == 8) {
        SegmentFlags p_flags;
    }
    Addr p_offset;
    Addr p_vaddr;
    Addr p_paddr;
    Addr p_filesz;
    Addr p_memsz;
    if (sizeof(Addr) == 4) {
        SegmentFlags p_flags;
    }
    Addr p_align;
    u32 flagsValue = std::mem::read_unsigned(addressof(this) + (sizeof(Addr) == 8 ? 4 : 24), 4);
    if (p_filesz > 0) {
        u64 contents = dataOffsetOf(imageStart, p_offset);
        match (typeValue) {
            (SegmentType::Interp): char interpreter[p_filesz] @ contents;
            (SegmentType::Dynamic): DynamicSection<Addr, p_filesz> dynamic @ contents;
            (SegmentType::Note | SegmentType::GnuProperty): NoteList<Addr, p_filesz> notes @ contents;
            (SegmentType::GnuEhFrame): EhFrameHeader<Addr> eh_frame_hdr @ contents;
            (0x70000000): if (isMips(machine)) { MipsRegisterInfo<Addr> reginfo @ contents; }
            (0x70000001): if (machine == Machine::Arm) { ArmExceptionIndex<p_filesz> exidx @ contents; }
            (0x70000003): ProcessorSegment processor @ contents;
            (_): padding[0];
        }
    }
    str summary = std::format("{} {:#x}-{:#x} {}", segmentTypeName(machine, typeValue, enumName(std::format("{}", p_type))), p_vaddr,
        p_vaddr + p_memsz, protectionString(flagsValue));
} [[format("summaryOf")]];

fn isMips(Machine machine) {
    return machine == Machine::Mips || machine == Machine::MipsRs3Le || machine == Machine::MipsX;
};

fn segmentTypeName(Machine machine, u32 type, str genericName) {
    if (type < 0x70000000 || type > 0x7fffffff) {
        return genericName;
    }
    if (machine == Machine::Arm) {
        match (type) {
            (0x70000000): return "ArmArchExt";
            (0x70000001): return "ArmExidx";
        }
    } else if (machine == Machine::AArch64) {
        match (type) {
            (0x70000002): return "AArch64MemtagMte";
        }
    } else if (isMips(machine)) {
        match (type) {
            (0x70000000): return "MipsRegInfo";
            (0x70000001): return "MipsRtProc";
            (0x70000002): return "MipsOptions";
            (0x70000003): return "MipsAbiFlags";
        }
    } else if (machine == Machine::RiscV) {
        match (type) {
            (0x70000003): return "RiscVAttributes";
        }
    }
    return genericName;
};

enum SegmentType : u32 {
    Null = 0,
    Load = 1,
    Dynamic = 2,
    Interp = 3,
    Note = 4,
    Shlib = 5,
    Phdr = 6,
    Tls = 7,
    GnuEhFrame = 0x6474e550,
    GnuStack = 0x6474e551,
    GnuRelro = 0x6474e552,
    GnuProperty = 0x6474e553,
    OpenBsdMutable = 0x65a3dbe5,
    OpenBsdRandomize = 0x65a3dbe6,
    OpenBsdWxNeeded = 0x65a3dbe7,
    OpenBsdNoBtCfi = 0x65a3dbe8,
    OpenBsdSyscalls = 0x65a3dbe9,
    OpenBsdBootData = 0x65a41be6,
    SunwBss = 0x6ffffffa,
    SunwStack = 0x6ffffffb,
    OsSpecific = 0x60000000 ... 0x6fffffff,
    ProcessorSpecific = 0x70000000 ... 0x7fffffff,
};

enum ArmSegmentType : u32 {
    ArchExt = 0x70000000,
    Exidx = 0x70000001,
};

enum AArch64SegmentType : u32 {
    MemtagMte = 0x70000002,
};

enum MipsSegmentType : u32 {
    RegInfo = 0x70000000,
    RtProc = 0x70000001,
    Options = 0x70000002,
    AbiFlags = 0x70000003,
};

enum RiscVSegmentType : u32 {
    Attributes = 0x70000003,
};

struct ProcessorSegment {
    if (isMips(parent.machine)) {
        MipsAbiFlags abiflags [[inline]];
    } else if (parent.machine == Machine::RiscV) {
        BuildAttributes<parent.p_filesz> attributes [[inline]];
    }
};

struct SegmentFlags {
    u32 value;
    str summary = protectionString(value);
} [[format("summaryOf")]];

fn protectionString(u32 flags) {
    return ((flags & 4) != 0 ? "r" : "-") + ((flags & 2) != 0 ? "w" : "-") + ((flags & 1) != 0 ? "x" : "-");
};

struct SectionHeader<Addr> {
    u64 imageStart = parent.imageStart;
    Machine machine = parent.header.e_machine;
    u32 sh_name;
    u32 typeValue = std::mem::read_unsigned($, 4);
    SectionType sh_type;
    if (typeValue >= 0x70000000 && typeValue <= 0x7fffffff) {
        if (machine == Machine::Arm) {
            ArmSectionType arm_type @ addressof(sh_type) [[no_unique_address]];
        } else if (machine == Machine::AArch64) {
            AArch64SectionType aarch64_type @ addressof(sh_type) [[no_unique_address]];
        } else if (isMips(machine)) {
            MipsSectionType mips_type @ addressof(sh_type) [[no_unique_address]];
        } else if (machine == Machine::RiscV) {
            RiscVSectionType riscv_type @ addressof(sh_type) [[no_unique_address]];
        } else if (machine == Machine::X86_64) {
            X86_64SectionType x86_64_type @ addressof(sh_type) [[no_unique_address]];
        }
    }
    SectionFlags<Addr> sh_flags;
    Addr sh_addr;
    Addr sh_offset;
    Addr sh_size;
    u32 sh_link;
    u32 sh_info;
    Addr sh_addralign;
    Addr sh_entsize;
    char name[] @ parent.sectionNames + sh_name;
    u64 symbolTable = dataOffsetOf(imageStart, sectionOffset(imageStart, sh_link));
    u64 stringTable = dataOffsetOf(imageStart, sectionOffset(imageStart, sh_link));
    u64 symbolStrings = dataOffsetOf(imageStart, sectionOffset(imageStart, sectionLink(imageStart, sh_link)));
    if (typeValue != SectionType::Null && typeValue != SectionType::NoBits && sh_size > 0 && fileOffsetIsMapped(imageStart, sh_offset)) {
        u64 contents = dataOffsetOf(imageStart, sh_offset);
        if ((sh_flags.value & 0x800) != 0) {
            CompressedSection<Addr> compressed @ contents;
        } else {
            match (typeValue) {
                (SectionType::ProgBits): SectionContents<Addr> data @ contents;
                (SectionType::SymTab | SectionType::DynSym): SymbolTable<Addr, sh_size / sh_entsize> symbols @ contents;
                (SectionType::StrTab): CString strings[while($ < contents + sh_size)] @ contents;
                (SectionType::Rela): Relocation<Addr, true> relocations[sh_size / sh_entsize] @ contents;
                (SectionType::Rel): Relocation<Addr, false> relocations[sh_size / sh_entsize] @ contents;
                (SectionType::Hash): SysvHash hash @ contents;
                (SectionType::Dynamic): DynamicEntry<Addr> entries[sh_size / sh_entsize] @ contents;
                (SectionType::Note): NoteList<Addr, sh_size> notes @ contents;
                (SectionType::InitArray | SectionType::FiniArray | SectionType::PreinitArray):
                    Addr functions[sh_size / sizeof(Addr)] @ contents;
                (SectionType::Group): SectionGroup<sh_size> group @ contents;
                (SectionType::SymTabShndx): u32 indices[sh_size / 4] @ contents;
                (SectionType::Relr | SectionType::AndroidRelr): RelativeRelocation<Addr> relocations[sh_size / sizeof(Addr)] @ contents;
                (SectionType::GnuAttributes): BuildAttributes<sh_size> attributes @ contents;
                (SectionType::GnuHash): GnuHash<Addr, sh_size> hash @ contents;
                (SectionType::GnuVerdef): VersionDefinition definitions[sh_info] @ contents;
                (SectionType::GnuVerneed): VersionRequirement requirements[sh_info] @ contents;
                (SectionType::GnuVersym): VersionIndex versions[sh_size / 2] @ contents;
                (0x70000001 | 0x70000003 | 0x70000006 | 0x7000002a): ProcessorSection<Addr> processor @ contents;
                (_): u8 bytes[sh_size] @ contents [[sealed]];
            }
        }
    }
    str typeName = sectionTypeName(machine, typeValue, enumName(std::format("{}", sh_type)));
    str summary = std::format("{} {} {:#x}-{:#x} {}", name, typeName, sh_addr, sh_addr + sh_size, std::core::formatted_value(sh_flags));
} [[format("summaryOf")]];

struct ProcessorSection<Addr> {
    u64 imageStart = parent.imageStart;
    Machine machine = parent.machine;
    u64 size = parent.sh_size;
    if (parent.typeValue == 0x70000001 && machine == Machine::Arm) {
        ArmExceptionIndex<size> exidx [[inline]];
    } else if (parent.typeValue == 0x70000003 && (machine == Machine::Arm || machine == Machine::RiscV || machine == Machine::AArch64)) {
        BuildAttributes<size> attributes [[inline]];
    } else if (parent.typeValue == 0x70000006 && isMips(machine)) {
        MipsRegisterInfo<Addr> reginfo [[inline]];
    } else if (parent.typeValue == 0x7000002a && isMips(machine)) {
        MipsAbiFlags abiflags [[inline]];
    } else {
        u8 bytes[size] [[sealed]];
    }
};

fn sectionTypeName(Machine machine, u32 type, str genericName) {
    if (type < 0x70000000 || type > 0x7fffffff) {
        return genericName;
    }
    if (machine == Machine::Arm) {
        match (type) {
            (0x70000001): return "ArmExidx";
            (0x70000002): return "ArmPreemptMap";
            (0x70000003): return "ArmAttributes";
            (0x70000004): return "ArmDebugOverlay";
            (0x70000005): return "ArmOverlaySection";
        }
    } else if (machine == Machine::AArch64) {
        match (type) {
            (0x70000003): return "AArch64Attributes";
            (0x70000004): return "AArch64AuthRelr";
            (0x70000007): return "AArch64MemtagGlobalsStatic";
            (0x70000008): return "AArch64MemtagGlobalsDynamic";
        }
    } else if (isMips(machine)) {
        match (type) {
            (0x70000006): return "MipsRegInfo";
            (0x7000000d): return "MipsOptions";
            (0x7000001e): return "MipsDwarf";
            (0x7000002a): return "MipsAbiFlags";
            (0x7000002b): return "MipsXHash";
        }
    } else if (machine == Machine::RiscV) {
        match (type) {
            (0x70000003): return "RiscVAttributes";
        }
    } else if (machine == Machine::X86_64) {
        match (type) {
            (0x70000001): return "X86_64Unwind";
        }
    }
    return genericName;
};

enum SectionType : u32 {
    Null = 0,
    ProgBits = 1,
    SymTab = 2,
    StrTab = 3,
    Rela = 4,
    Hash = 5,
    Dynamic = 6,
    Note = 7,
    NoBits = 8,
    Rel = 9,
    Shlib = 10,
    DynSym = 11,
    InitArray = 14,
    FiniArray = 15,
    PreinitArray = 16,
    Group = 17,
    SymTabShndx = 18,
    Relr = 19,
    AndroidRel = 0x60000001,
    AndroidRela = 0x60000002,
    AndroidRelr = 0x6fffff00,
    GnuAttributes = 0x6ffffff5,
    GnuHash = 0x6ffffff6,
    GnuLiblist = 0x6ffffff7,
    Checksum = 0x6ffffff8,
    SunwMove = 0x6ffffffa,
    SunwComdat = 0x6ffffffb,
    SunwSyminfo = 0x6ffffffc,
    GnuVerdef = 0x6ffffffd,
    GnuVerneed = 0x6ffffffe,
    GnuVersym = 0x6fffffff,
    OsSpecific = 0x60000000 ... 0x6fffffff,
    ProcessorSpecific = 0x70000000 ... 0x7fffffff,
    UserSpecific = 0x80000000 ... 0xffffffff,
};

enum ArmSectionType : u32 {
    Exidx = 0x70000001,
    PreemptMap = 0x70000002,
    Attributes = 0x70000003,
    DebugOverlay = 0x70000004,
    OverlaySection = 0x70000005,
};

enum AArch64SectionType : u32 {
    Attributes = 0x70000003,
    AuthRelr = 0x70000004,
    MemtagGlobalsStatic = 0x70000007,
    MemtagGlobalsDynamic = 0x70000008,
};

enum MipsSectionType : u32 {
    Liblist = 0x70000000,
    Msym = 0x70000001,
    Conflict = 0x70000002,
    Gptab = 0x70000003,
    Ucode = 0x70000004,
    Debug = 0x70000005,
    RegInfo = 0x70000006,
    Package = 0x70000007,
    Packsym = 0x70000008,
    Reld = 0x70000009,
    Iface = 0x7000000b,
    Content = 0x7000000c,
    Options = 0x7000000d,
    Shdr = 0x70000010,
    Fdesc = 0x70000011,
    Extsym = 0x70000012,
    Dense = 0x70000013,
    Pdesc = 0x70000014,
    Locsym = 0x70000015,
    Auxsym = 0x70000016,
    Optsym = 0x70000017,
    Locstr = 0x70000018,
    Line = 0x70000019,
    Rfdesc = 0x7000001a,
    Deltasym = 0x7000001b,
    Deltainst = 0x7000001c,
    Deltaclass = 0x7000001d,
    Dwarf = 0x7000001e,
    Deltadecl = 0x7000001f,
    SymbolLib = 0x70000020,
    Events = 0x70000021,
    Translate = 0x70000022,
    Pixie = 0x70000023,
    Xlate = 0x70000024,
    XlateDebug = 0x70000025,
    Whirl = 0x70000026,
    EhRegion = 0x70000027,
    XlateOld = 0x70000028,
    PdrException = 0x70000029,
    AbiFlags = 0x7000002a,
    XHash = 0x7000002b,
};

enum RiscVSectionType : u32 {
    Attributes = 0x70000003,
};

enum X86_64SectionType : u32 {
    Unwind = 0x70000001,
};

struct SectionFlags<Addr> {
    Addr value;
    str summary = describeSectionFlags(value);
} [[format("summaryOf")]];

fn describeSectionFlags(u64 flags) {
    str names = "";
    names = names + flagName(flags, 0x1, "write");
    names = names + flagName(flags, 0x2, "alloc");
    names = names + flagName(flags, 0x4, "execinstr");
    names = names + flagName(flags, 0x10, "merge");
    names = names + flagName(flags, 0x20, "strings");
    names = names + flagName(flags, 0x40, "info_link");
    names = names + flagName(flags, 0x80, "link_order");
    names = names + flagName(flags, 0x100, "os_nonconforming");
    names = names + flagName(flags, 0x200, "group");
    names = names + flagName(flags, 0x400, "tls");
    names = names + flagName(flags, 0x800, "compressed");
    names = names + flagName(flags, 0x200000, "gnu_retain");
    names = names + flagName(flags, 0x40000000, "ordered");
    names = names + flagName(flags, 0x80000000, "exclude");
    if ((flags & 0x0ff00000 & ~0x200000) != 0) {
        names = names + std::format(", os {:#x}", flags & 0x0ff00000 & ~0x200000);
    }
    if ((flags & 0x30000000) != 0) {
        names = names + std::format(", processor {:#x}", flags & 0x30000000);
    }
    return flagList(names);
};

struct SectionContents<Addr> {
    u64 imageStart = parent.imageStart;
    Machine machine = parent.machine;
    u64 size = parent.sh_size;
    if (std::string::starts_with(parent.name, ".interp") || std::string::starts_with(parent.name, ".comment")
        || (parent.sh_flags.value & 0x20) != 0) {
        CString strings[while($ < addressof(this) + size)];
    } else if (std::string::starts_with(parent.name, ".eh_frame_hdr")) {
        EhFrameHeader<Addr> eh_frame_hdr;
    } else if (std::string::starts_with(parent.name, ".got") || std::string::starts_with(parent.name, ".plt.got")) {
        Addr pointers[size / sizeof(Addr)];
    } else if (std::string::starts_with(parent.name, ".ARM.exidx")) {
        ArmExceptionIndex<size> exidx;
    } else {
        u8 bytes[size] [[sealed]];
    }
};

struct CString {
    char text[];
    str summary = text;
} [[format("summaryOf")]];

struct CompressedSection<Addr> {
    CompressionType ch_type;
    if (sizeof(Addr) == 8) {
        u32 ch_reserved;
    }
    Addr ch_size;
    Addr ch_addralign;
    u8 compressed[parent.sh_size - sizeof(this)] [[sealed]];
    str summary = std::format("{} ({} bytes uncompressed)", enumName(std::format("{}", ch_type)), ch_size);
} [[format("summaryOf")]];

enum CompressionType : u32 {
    Zlib = 1,
    Zstd = 2,
    OsSpecific = 0x60000000 ... 0x6fffffff,
    ProcessorSpecific = 0x70000000 ... 0x7fffffff,
};

struct SymbolTable<Addr, auto Count> {
    u64 stringTable = parent.stringTable;
    if (sizeof(Addr) == 8) {
        Symbol64 symbols[Count];
    } else {
        Symbol32 symbols[Count];
    }
    str summary = std::format("{} symbols", Count);
} [[format("summaryOf")]];

struct Symbol32 {
    u32 st_name;
    u32 st_value;
    u32 st_size;
    SymbolInfo st_info;
    SymbolOther st_other;
    SectionIndex st_shndx;
    char name[] @ parent.stringTable + st_name;
    str summary = std::format("{} {}", name, std::core::formatted_value(st_info));
} [[format("summaryOf")]];

struct Symbol64 {
    u32 st_name;
    SymbolInfo st_info;
    SymbolOther st_other;
    SectionIndex st_shndx;
    u64 st_value;
    u64 st_size;
    char name[] @ parent.stringTable + st_name;
    str summary = std::format("{} {}", name, std::core::formatted_value(st_info));
} [[format("summaryOf")]];

bitfield SymbolInfo {
    SymbolType type : 4;
    SymbolBinding binding : 4;
} [[format("describeSymbolInfo")]];

fn describeSymbolInfo(ref auto info) {
    return symbolBindingName(info.binding) + " " + symbolTypeName(info.type);
};

fn symbolBindingName(u8 binding) {
    match (binding) {
        (0): return "local";
        (1): return "global";
        (2): return "weak";
        (10): return "unique";
        (13 ... 15): return std::format("processor binding {}", binding);
        (_): return std::format("binding {}", binding);
    }
};

fn symbolTypeName(u8 type) {
    match (type) {
        (0): return "notype";
        (1): return "object";
        (2): return "func";
        (3): return "section";
        (4): return "file";
        (5): return "common";
        (6): return "tls";
        (10): return "ifunc";
        (13 ... 15): return std::format("processor type {}", type);
        (_): return std::format("type {}", type);
    }
};

enum SymbolType : u8 {
    NoType = 0,
    Object = 1,
    Func = 2,
    Section = 3,
    File = 4,
    Common = 5,
    Tls = 6,
    GnuIFunc = 10,
    OsSpecific = 11 ... 12,
    ProcessorSpecific = 13 ... 15,
};

enum SymbolBinding : u8 {
    Local = 0,
    Global = 1,
    Weak = 2,
    GnuUnique = 10,
    OsSpecific = 11 ... 12,
    ProcessorSpecific = 13 ... 15,
};

bitfield SymbolOther {
    SymbolVisibility visibility : 2;
    padding : 6;
};

enum SymbolVisibility : u8 {
    Default = 0,
    Internal = 1,
    Hidden = 2,
    Protected = 3,
};

enum SectionIndex : u16 {
    Undefined = 0,
    Before = 0xff00,
    After = 0xff01,
    ProcessorSpecific = 0xff00 ... 0xff1f,
    OsSpecific = 0xff20 ... 0xff3f,
    Absolute = 0xfff1,
    Common = 0xfff2,
    ExtendedIndex = 0xffff,
    Section = 1 ... 0xfeff,
};

struct Relocation<Addr, auto HasAddend> {
    Machine machine = parent.machine;
    Addr r_offset;
    if (machine == Machine::X86_64) {
        RelocationInfo<Addr, X86_64RelocationType> r_info;
    } else if (machine == Machine::I386) {
        RelocationInfo<Addr, I386RelocationType> r_info;
    } else if (machine == Machine::AArch64) {
        RelocationInfo<Addr, AArch64RelocationType> r_info;
    } else if (machine == Machine::Arm) {
        RelocationInfo<Addr, ArmRelocationType> r_info;
    } else if (machine == Machine::RiscV) {
        RelocationInfo<Addr, RiscVRelocationType> r_info;
    } else if (isMips(machine) && sizeof(Addr) == 8) {
        Mips64RelocationInfo r_info;
    } else if (isMips(machine)) {
        RelocationInfo<Addr, MipsRelocationType> r_info;
    } else {
        RelocationInfo<Addr, u32> r_info;
    }
    if (HasAddend) {
        if (sizeof(Addr) == 8) {
            s64 r_addend;
        } else {
            s32 r_addend;
        }
    }
    u64 symbolIndex = std::mem::read_unsigned(addressof(r_offset) + sizeof(Addr), sizeof(Addr)) >> (sizeof(Addr) == 8 ? 32 : 8);
    if (symbolIndex != 0) {
        u64 symbolEntry = parent.symbolTable + symbolIndex * (sizeof(Addr) == 8 ? 24 : 16);
        char symbol[] @ parent.symbolStrings + std::mem::read_unsigned(symbolEntry, 4);
        str summary = std::format("{:#x} {}", r_offset, symbol);
    } else {
        str summary = std::format("{:#x}", r_offset);
    }
} [[format("summaryOf")]];

bitfield RelocationInfo<Addr, Type> {
    Type r_type : (sizeof(Addr) == 8 ? 32 : 8);
    u32 r_sym : (sizeof(Addr) == 8 ? 32 : 24);
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, sizeof(Addr) * 8)]];

struct Mips64RelocationInfo {
    u32 r_sym;
    u8 r_ssym;
    MipsRelocationType r_type3;
    MipsRelocationType r_type2;
    MipsRelocationType r_type;
};

enum X86_64RelocationType : u32 {
    None = 0,
    R64 = 1,
    Pc32 = 2,
    Got32 = 3,
    Plt32 = 4,
    Copy = 5,
    GlobDat = 6,
    JumpSlot = 7,
    Relative = 8,
    GotPcRel = 9,
    R32 = 10,
    R32S = 11,
    R16 = 12,
    Pc16 = 13,
    R8 = 14,
    Pc8 = 15,
    DtpMod64 = 16,
    DtpOff64 = 17,
    TpOff64 = 18,
    TlsGd = 19,
    TlsLd = 20,
    DtpOff32 = 21,
    GotTpOff = 22,
    TpOff32 = 23,
    Pc64 = 24,
    GotOff64 = 25,
    GotPc32 = 26,
    Got64 = 27,
    GotPcRel64 = 28,
    GotPc64 = 29,
    GotPlt64 = 30,
    PltOff64 = 31,
    Size32 = 32,
    Size64 = 33,
    GotPc32TlsDesc = 34,
    TlsDescCall = 35,
    TlsDesc = 36,
    IRelative = 37,
    Relative64 = 38,
    GotPcRelX = 41,
    RexGotPcRelX = 42,
    Code4GotPcRelX = 43,
    Code4GotTpOff = 44,
    Code4GotPc32TlsDesc = 45,
    Code6GotTpOff = 50,
};

enum I386RelocationType : u32 {
    None = 0,
    R32 = 1,
    Pc32 = 2,
    Got32 = 3,
    Plt32 = 4,
    Copy = 5,
    GlobDat = 6,
    JumpSlot = 7,
    Relative = 8,
    GotOff = 9,
    GotPc = 10,
    R32Plt = 11,
    TlsTpOff = 14,
    TlsIe = 15,
    TlsGotIe = 16,
    TlsLe = 17,
    TlsGd = 18,
    TlsLdm = 19,
    R16 = 20,
    Pc16 = 21,
    R8 = 22,
    Pc8 = 23,
    TlsGd32 = 24,
    TlsGdPush = 25,
    TlsGdCall = 26,
    TlsGdPop = 27,
    TlsLdm32 = 28,
    TlsLdmPush = 29,
    TlsLdmCall = 30,
    TlsLdmPop = 31,
    TlsLdo32 = 32,
    TlsIe32 = 33,
    TlsLe32 = 34,
    TlsDtpMod32 = 35,
    TlsDtpOff32 = 36,
    TlsTpOff32 = 37,
    Size32 = 38,
    TlsGotDesc = 39,
    TlsDescCall = 40,
    TlsDesc = 41,
    IRelative = 42,
    Got32X = 43,
};

enum AArch64RelocationType : u32 {
    None = 0,
    Abs64 = 0x101,
    Abs32 = 0x102,
    Abs16 = 0x103,
    Prel64 = 0x104,
    Prel32 = 0x105,
    Prel16 = 0x106,
    MovwUabsG0 = 0x107,
    MovwUabsG0Nc = 0x108,
    MovwUabsG1 = 0x109,
    MovwUabsG1Nc = 0x10a,
    MovwUabsG2 = 0x10b,
    MovwUabsG2Nc = 0x10c,
    MovwUabsG3 = 0x10d,
    MovwSabsG0 = 0x10e,
    MovwSabsG1 = 0x10f,
    MovwSabsG2 = 0x110,
    LdPrelLo19 = 0x111,
    AdrPrelLo21 = 0x112,
    AdrPrelPgHi21 = 0x113,
    AdrPrelPgHi21Nc = 0x114,
    AddAbsLo12Nc = 0x115,
    Ldst8AbsLo12Nc = 0x116,
    Tstbr14 = 0x117,
    Condbr19 = 0x118,
    Jump26 = 0x11a,
    Call26 = 0x11b,
    Ldst16AbsLo12Nc = 0x11c,
    Ldst32AbsLo12Nc = 0x11d,
    Ldst64AbsLo12Nc = 0x11e,
    MovwPrelG0 = 0x11f,
    MovwPrelG0Nc = 0x120,
    MovwPrelG1 = 0x121,
    MovwPrelG1Nc = 0x122,
    MovwPrelG2 = 0x123,
    MovwPrelG2Nc = 0x124,
    MovwPrelG3 = 0x125,
    Ldst128AbsLo12Nc = 0x12b,
    MovwGotoffG0 = 0x12c,
    MovwGotoffG0Nc = 0x12d,
    MovwGotoffG1 = 0x12e,
    MovwGotoffG1Nc = 0x12f,
    MovwGotoffG2 = 0x130,
    MovwGotoffG2Nc = 0x131,
    MovwGotoffG3 = 0x132,
    Gotrel64 = 0x133,
    Gotrel32 = 0x134,
    GotLdPrel19 = 0x135,
    Ld64GotoffLo15 = 0x136,
    AdrGotPage = 0x137,
    Ld64GotLo12Nc = 0x138,
    Ld64GotpageLo15 = 0x139,
    Plt32 = 0x13a,
    GotPcRel32 = 0x13b,
    PatchInst = 0x13c,
    FuncInit64 = 0x13d,
    TlsgdAdrPrel21 = 0x200,
    TlsgdAdrPage21 = 0x201,
    TlsgdAddLo12Nc = 0x202,
    TlsgdMovwG1 = 0x203,
    TlsgdMovwG0Nc = 0x204,
    TlsldAdrPrel21 = 0x205,
    TlsldAdrPage21 = 0x206,
    TlsldAddLo12Nc = 0x207,
    TlsldMovwG1 = 0x208,
    TlsldMovwG0Nc = 0x209,
    TlsldLdPrel19 = 0x20a,
    TlsldMovwDtprelG2 = 0x20b,
    TlsldMovwDtprelG1 = 0x20c,
    TlsldMovwDtprelG1Nc = 0x20d,
    TlsldMovwDtprelG0 = 0x20e,
    TlsldMovwDtprelG0Nc = 0x20f,
    TlsldAddDtprelHi12 = 0x210,
    TlsldAddDtprelLo12 = 0x211,
    TlsldAddDtprelLo12Nc = 0x212,
    TlsldLdst8DtprelLo12 = 0x213,
    TlsldLdst8DtprelLo12Nc = 0x214,
    TlsldLdst16DtprelLo12 = 0x215,
    TlsldLdst16DtprelLo12Nc = 0x216,
    TlsldLdst32DtprelLo12 = 0x217,
    TlsldLdst32DtprelLo12Nc = 0x218,
    TlsldLdst64DtprelLo12 = 0x219,
    TlsldLdst64DtprelLo12Nc = 0x21a,
    TlsieMovwGottprelG1 = 0x21b,
    TlsieMovwGottprelG0Nc = 0x21c,
    TlsieAdrGottprelPage21 = 0x21d,
    TlsieLd64GottprelLo12Nc = 0x21e,
    TlsieLdGottprelPrel19 = 0x21f,
    TlsleMovwTprelG2 = 0x220,
    TlsleMovwTprelG1 = 0x221,
    TlsleMovwTprelG1Nc = 0x222,
    TlsleMovwTprelG0 = 0x223,
    TlsleMovwTprelG0Nc = 0x224,
    TlsleAddTprelHi12 = 0x225,
    TlsleAddTprelLo12 = 0x226,
    TlsleAddTprelLo12Nc = 0x227,
    TlsleLdst8TprelLo12 = 0x228,
    TlsleLdst8TprelLo12Nc = 0x229,
    TlsleLdst16TprelLo12 = 0x22a,
    TlsleLdst16TprelLo12Nc = 0x22b,
    TlsleLdst32TprelLo12 = 0x22c,
    TlsleLdst32TprelLo12Nc = 0x22d,
    TlsleLdst64TprelLo12 = 0x22e,
    TlsleLdst64TprelLo12Nc = 0x22f,
    TlsdescLdPrel19 = 0x230,
    TlsdescAdrPrel21 = 0x231,
    TlsdescAdrPage21 = 0x232,
    TlsdescLd64Lo12 = 0x233,
    TlsdescAddLo12 = 0x234,
    TlsdescOffG1 = 0x235,
    TlsdescOffG0Nc = 0x236,
    TlsdescLdr = 0x237,
    TlsdescAdd = 0x238,
    TlsdescCall = 0x239,
    TlsleLdst128TprelLo12 = 0x23a,
    TlsleLdst128TprelLo12Nc = 0x23b,
    TlsldLdst128DtprelLo12 = 0x23c,
    TlsldLdst128DtprelLo12Nc = 0x23d,
    AuthAbs64 = 0x244,
    AuthMovwGotoffG0 = 0x245,
    AuthMovwGotoffG0Nc = 0x246,
    AuthMovwGotoffG1 = 0x247,
    AuthMovwGotoffG1Nc = 0x248,
    AuthMovwGotoffG2 = 0x249,
    AuthMovwGotoffG2Nc = 0x24a,
    AuthMovwGotoffG3 = 0x24b,
    AuthGotLdPrel19 = 0x24c,
    AuthLd64GotoffLo15 = 0x24d,
    AuthAdrGotPage = 0x24e,
    AuthLd64GotLo12Nc = 0x24f,
    AuthLd64GotpageLo15 = 0x250,
    AuthGotAddLo12Nc = 0x251,
    AuthGotAdrPrelLo21 = 0x252,
    AuthTlsdescAdrPage21 = 0x253,
    AuthTlsdescLd64Lo12 = 0x254,
    AuthTlsdescAddLo12 = 0x255,
    Copy = 0x400,
    GlobDat = 0x401,
    JumpSlot = 0x402,
    Relative = 0x403,
    TlsDtpMod64 = 0x404,
    TlsDtpRel64 = 0x405,
    TlsTpRel64 = 0x406,
    Tlsdesc = 0x407,
    IRelative = 0x408,
    AuthRelative = 0x411,
    AuthGlobDat = 0x412,
    AuthTlsdesc = 0x413,
    AuthIRelative = 0x414,
};

enum ArmRelocationType : u32 {
    None = 0x00,
    Pc24 = 0x01,
    Abs32 = 0x02,
    Rel32 = 0x03,
    LdrPcG0 = 0x04,
    Abs16 = 0x05,
    Abs12 = 0x06,
    ThmAbs5 = 0x07,
    Abs8 = 0x08,
    Sbrel32 = 0x09,
    ThmCall = 0x0a,
    ThmPc8 = 0x0b,
    BrelAdj = 0x0c,
    TlsDesc = 0x0d,
    ThmSwi8 = 0x0e,
    Xpc25 = 0x0f,
    ThmXpc22 = 0x10,
    TlsDtpMod32 = 0x11,
    TlsDtpOff32 = 0x12,
    TlsTpOff32 = 0x13,
    Copy = 0x14,
    GlobDat = 0x15,
    JumpSlot = 0x16,
    Relative = 0x17,
    Gotoff32 = 0x18,
    BasePrel = 0x19,
    GotBrel = 0x1a,
    Plt32 = 0x1b,
    Call = 0x1c,
    Jump24 = 0x1d,
    ThmJump24 = 0x1e,
    BaseAbs = 0x1f,
    AluPcrel7_0 = 0x20,
    AluPcrel15_8 = 0x21,
    AluPcrel23_15 = 0x22,
    LdrSbrel11_0Nc = 0x23,
    AluSbrel19_12Nc = 0x24,
    AluSbrel27_20Ck = 0x25,
    Target1 = 0x26,
    Sbrel31 = 0x27,
    V4Bx = 0x28,
    Target2 = 0x29,
    Prel31 = 0x2a,
    MovwAbsNc = 0x2b,
    MovtAbs = 0x2c,
    MovwPrelNc = 0x2d,
    MovtPrel = 0x2e,
    ThmMovwAbsNc = 0x2f,
    ThmMovtAbs = 0x30,
    ThmMovwPrelNc = 0x31,
    ThmMovtPrel = 0x32,
    ThmJump19 = 0x33,
    ThmJump6 = 0x34,
    ThmAluPrel11_0 = 0x35,
    ThmPc12 = 0x36,
    Abs32Noi = 0x37,
    Rel32Noi = 0x38,
    AluPcG0Nc = 0x39,
    AluPcG0 = 0x3a,
    AluPcG1Nc = 0x3b,
    AluPcG1 = 0x3c,
    AluPcG2 = 0x3d,
    LdrPcG1 = 0x3e,
    LdrPcG2 = 0x3f,
    LdrsPcG0 = 0x40,
    LdrsPcG1 = 0x41,
    LdrsPcG2 = 0x42,
    LdcPcG0 = 0x43,
    LdcPcG1 = 0x44,
    LdcPcG2 = 0x45,
    AluSbG0Nc = 0x46,
    AluSbG0 = 0x47,
    AluSbG1Nc = 0x48,
    AluSbG1 = 0x49,
    AluSbG2 = 0x4a,
    LdrSbG0 = 0x4b,
    LdrSbG1 = 0x4c,
    LdrSbG2 = 0x4d,
    LdrsSbG0 = 0x4e,
    LdrsSbG1 = 0x4f,
    LdrsSbG2 = 0x50,
    LdcSbG0 = 0x51,
    LdcSbG1 = 0x52,
    LdcSbG2 = 0x53,
    MovwBrelNc = 0x54,
    MovtBrel = 0x55,
    MovwBrel = 0x56,
    ThmMovwBrelNc = 0x57,
    ThmMovtBrel = 0x58,
    ThmMovwBrel = 0x59,
    TlsGotdesc = 0x5a,
    TlsCall = 0x5b,
    TlsDescseq = 0x5c,
    ThmTlsCall = 0x5d,
    Plt32Abs = 0x5e,
    GotAbs = 0x5f,
    GotPrel = 0x60,
    GotBrel12 = 0x61,
    Gotoff12 = 0x62,
    Gotrelax = 0x63,
    GnuVtentry = 0x64,
    GnuVtinherit = 0x65,
    ThmJump11 = 0x66,
    ThmJump8 = 0x67,
    TlsGd32 = 0x68,
    TlsLdm32 = 0x69,
    TlsLdo32 = 0x6a,
    TlsIe32 = 0x6b,
    TlsLe32 = 0x6c,
    TlsLdo12 = 0x6d,
    TlsLe12 = 0x6e,
    TlsIe12Gp = 0x6f,
    Private = 0x70 ... 0x7f,
    MeToo = 0x80,
    ThmTlsDescseq16 = 0x81,
    ThmTlsDescseq32 = 0x82,
    ThmAluAbsG0Nc = 0x84,
    ThmAluAbsG1Nc = 0x85,
    ThmAluAbsG2Nc = 0x86,
    ThmAluAbsG3 = 0x87,
    ThmBf16 = 0x88,
    ThmBf12 = 0x89,
    ThmBf18 = 0x8a,
    IRelative = 0xa0,
    GotFuncDesc = 0xa1,
    GotOffFuncDesc = 0xa2,
    FuncDesc = 0xa3,
    FuncDescValue = 0xa4,
    TlsGd32Fdpic = 0xa5,
    TlsLdm32Fdpic = 0xa6,
    TlsIe32Fdpic = 0xa7,
    Rxpc25 = 0xf9,
    Rsbrel32 = 0xfa,
    ThmRpc22 = 0xfb,
    Rrel32 = 0xfc,
    Rabs22 = 0xfd,
    Rpc24 = 0xfe,
    Rbase = 0xff,
};

enum RiscVRelocationType : u32 {
    None = 0,
    R32 = 1,
    R64 = 2,
    Relative = 3,
    Copy = 4,
    JumpSlot = 5,
    TlsDtpMod32 = 6,
    TlsDtpMod64 = 7,
    TlsDtpRel32 = 8,
    TlsDtpRel64 = 9,
    TlsTpRel32 = 10,
    TlsTpRel64 = 11,
    TlsDesc = 12,
    Branch = 16,
    Jal = 17,
    Call = 18,
    CallPlt = 19,
    GotHi20 = 20,
    TlsGotHi20 = 21,
    TlsGdHi20 = 22,
    PcRelHi20 = 23,
    PcRelLo12I = 24,
    PcRelLo12S = 25,
    Hi20 = 26,
    Lo12I = 27,
    Lo12S = 28,
    TpRelHi20 = 29,
    TpRelLo12I = 30,
    TpRelLo12S = 31,
    TpRelAdd = 32,
    Add8 = 33,
    Add16 = 34,
    Add32 = 35,
    Add64 = 36,
    Sub8 = 37,
    Sub16 = 38,
    Sub32 = 39,
    Sub64 = 40,
    Got32PcRel = 41,
    Align = 43,
    RvcBranch = 44,
    RvcJump = 45,
    Relax = 51,
    Sub6 = 52,
    Set6 = 53,
    Set8 = 54,
    Set16 = 55,
    Set32 = 56,
    R32PcRel = 57,
    IRelative = 58,
    Plt32 = 59,
    SetUleb128 = 60,
    SubUleb128 = 61,
    TlsDescHi20 = 62,
    TlsDescLoadLo12 = 63,
    TlsDescAddLo12 = 64,
    TlsDescCall = 65,
    Vendor = 191,
    Custom = 192 ... 255,
};

enum MipsRelocationType : u8 {
    None = 0,
    R16 = 1,
    R32 = 2,
    Rel32 = 3,
    R26 = 4,
    Hi16 = 5,
    Lo16 = 6,
    GpRel16 = 7,
    Literal = 8,
    Got16 = 9,
    Pc16 = 10,
    Call16 = 11,
    GpRel32 = 12,
    Shift5 = 16,
    Shift6 = 17,
    R64 = 18,
    GotDisp = 19,
    GotPage = 20,
    GotOfst = 21,
    GotHi16 = 22,
    GotLo16 = 23,
    Sub = 24,
    InsertA = 25,
    InsertB = 26,
    Delete = 27,
    Higher = 28,
    Highest = 29,
    CallHi16 = 30,
    CallLo16 = 31,
    ScnDisp = 32,
    Rel16 = 33,
    AddImmediate = 34,
    PJump = 35,
    RelGot = 36,
    Jalr = 37,
    TlsDtpMod32 = 38,
    TlsDtpRel32 = 39,
    TlsDtpMod64 = 40,
    TlsDtpRel64 = 41,
    TlsGd = 42,
    TlsLdm = 43,
    TlsDtpRelHi16 = 44,
    TlsDtpRelLo16 = 45,
    TlsGotTpRel = 46,
    TlsTpRel32 = 47,
    TlsTpRel64 = 48,
    TlsTpRelHi16 = 49,
    TlsTpRelLo16 = 50,
    GlobDat = 51,
    Pc21S2 = 60,
    Pc26S2 = 61,
    Pc18S3 = 62,
    Pc19S2 = 63,
    PcHi16 = 64,
    PcLo16 = 65,
    Mips16_26 = 100,
    Mips16GpRel = 101,
    Mips16Got16 = 102,
    Mips16Call16 = 103,
    Mips16Hi16 = 104,
    Mips16Lo16 = 105,
    Mips16TlsGd = 106,
    Mips16TlsLdm = 107,
    Mips16TlsDtpRelHi16 = 108,
    Mips16TlsDtpRelLo16 = 109,
    Mips16TlsGotTpRel = 110,
    Mips16TlsTpRelHi16 = 111,
    Mips16TlsTpRelLo16 = 112,
    Copy = 126,
    JumpSlot = 127,
    MicroMips26S1 = 133,
    MicroMipsHi16 = 134,
    MicroMipsLo16 = 135,
    MicroMipsGpRel16 = 136,
    MicroMipsLiteral = 137,
    MicroMipsGot16 = 138,
    MicroMipsPc7S1 = 139,
    MicroMipsPc10S1 = 140,
    MicroMipsPc16S1 = 141,
    MicroMipsCall16 = 142,
    MicroMipsGotDisp = 145,
    MicroMipsGotPage = 146,
    MicroMipsGotOfst = 147,
    MicroMipsGotHi16 = 148,
    MicroMipsGotLo16 = 149,
    MicroMipsSub = 150,
    MicroMipsHigher = 151,
    MicroMipsHighest = 152,
    MicroMipsCallHi16 = 153,
    MicroMipsCallLo16 = 154,
    MicroMipsScnDisp = 155,
    MicroMipsJalr = 156,
    MicroMipsHi0Lo16 = 157,
    MicroMipsTlsGd = 162,
    MicroMipsTlsLdm = 163,
    MicroMipsTlsDtpRelHi16 = 164,
    MicroMipsTlsDtpRelLo16 = 165,
    MicroMipsTlsGotTpRel = 166,
    MicroMipsTlsTpRelHi16 = 169,
    MicroMipsTlsTpRelLo16 = 170,
    MicroMipsGpRel7S2 = 172,
    MicroMipsPc23S2 = 173,
    MicroMipsPc21S1 = 174,
    MicroMipsPc26S1 = 175,
    MicroMipsPc18S3 = 176,
    MicroMipsPc19S2 = 177,
    Pc32 = 248,
    Eh = 249,
};

struct RelativeRelocation<Addr> {
    Addr entry [[format("formatRelativeRelocation")]];
    str summary = formatRelativeRelocation(entry);
} [[format("summaryOf")]];

fn formatRelativeRelocation(u64 entry) {
    if ((entry & 1) == 0) {
        return std::format("address {:#x}", entry);
    }
    return std::format("bitmap {:#x}", entry >> 1);
};

struct SysvHash {
    u32 nbucket;
    u32 nchain;
    u32 bucket[nbucket];
    u32 chain[nchain];
    str summary = std::format("{} buckets, {} chains", nbucket, nchain);
} [[format("summaryOf")]];

struct GnuHash<Addr, auto Size> {
    u32 nbuckets;
    u32 symoffset;
    u32 bloom_size;
    u32 bloom_shift;
    Addr bloom[bloom_size];
    u32 buckets[nbuckets];
    u32 chains[while($ < addressof(this) + Size)];
    str summary = std::format("{} buckets, symbols from {}", nbuckets, symoffset);
} [[format("summaryOf")]];

struct DynamicEntry<Addr> {
    u64 tagValue = std::mem::read_unsigned($, sizeof(Addr));
    DynamicTag<Addr> d_tag;
    DynamicValue<Addr> d_un;
    str summary = std::format("{} {}", std::core::formatted_value(d_tag), std::core::formatted_value(d_un));
} [[format("summaryOf")]];

struct DynamicValue<Addr> {
    u64 tag = parent.tagValue;
    if (tag == DynamicTagValue::Flags) {
        Addr d_val;
        str summary = describeDynamicFlags(d_val);
    } else if (tag == DynamicTagValue::Flags1) {
        Addr d_val;
        str summary = describeDynamicFlags1(d_val);
    } else if (tag == DynamicTagValue::PosFlag1) {
        Addr d_val;
        str summary = describeDynamicPositionalFlags(d_val);
    } else if (tag == DynamicTagValue::Feature1) {
        Addr d_val;
        str summary = describeDynamicFeatures(d_val);
    } else if (tag == DynamicTagValue::PltRel) {
        Addr d_val;
        str summary = d_val == DynamicTagValue::Rela ? "Rela" : (d_val == DynamicTagValue::Rel ? "Rel" : std::format("{}", d_val));
    } else if (namesString(tag)) {
        Addr d_val;
        char string[] @ parent.parent.stringTable + d_val;
        str summary = string;
    } else if (holdsCount(tag)) {
        Addr d_val;
        str summary = std::format("{}", d_val);
    } else {
        Addr d_ptr;
        str summary = std::format("{:#x}", d_ptr);
    }
} [[format("summaryOf")]];

struct DynamicTag<Addr> {
    if (sizeof(Addr) == 4) {
        DynamicTagValue tag;
        str summary = enumName(std::format("{}", tag));
    } else if (std::mem::read_unsigned($, 4) == std::mem::read_unsigned($, 4, std::mem::Endian::Little)) {
        DynamicTagValue tag;
        padding[4];
        str summary = enumName(std::format("{}", tag));
    } else {
        padding[4];
        DynamicTagValue tag;
        str summary = enumName(std::format("{}", tag));
    }
} [[format("summaryOf")]];

fn namesString(u64 tag) {
    match (tag) {
        (DynamicTagValue::Needed | DynamicTagValue::Soname | DynamicTagValue::Rpath | DynamicTagValue::Runpath | DynamicTagValue::Auxiliary
            | DynamicTagValue::Filter | DynamicTagValue::Config | DynamicTagValue::DepAudit | DynamicTagValue::Audit): return true;
        (_): return false;
    }
};

fn holdsCount(u64 tag) {
    match (tag) {
        (DynamicTagValue::Null | DynamicTagValue::Symbolic | DynamicTagValue::TextRel | DynamicTagValue::BindNow | DynamicTagValue::PltRelSz
            | DynamicTagValue::RelaSz | DynamicTagValue::RelaEnt | DynamicTagValue::StrSz | DynamicTagValue::SymEnt | DynamicTagValue::RelSz
            | DynamicTagValue::RelEnt | DynamicTagValue::InitArraySz | DynamicTagValue::FiniArraySz | DynamicTagValue::PreinitArraySz
            | DynamicTagValue::RelrSz | DynamicTagValue::RelrEnt | DynamicTagValue::RelaCount | DynamicTagValue::RelCount
            | DynamicTagValue::VerDefNum | DynamicTagValue::VerNeedNum): return true;
        (_): return false;
    }
};

enum DynamicTagValue : u32 {
    Null = 0,
    Needed = 1,
    PltRelSz = 2,
    PltGot = 3,
    Hash = 4,
    StrTab = 5,
    SymTab = 6,
    Rela = 7,
    RelaSz = 8,
    RelaEnt = 9,
    StrSz = 10,
    SymEnt = 11,
    Init = 12,
    Fini = 13,
    Soname = 14,
    Rpath = 15,
    Symbolic = 16,
    Rel = 17,
    RelSz = 18,
    RelEnt = 19,
    PltRel = 20,
    Debug = 21,
    TextRel = 22,
    JmpRel = 23,
    BindNow = 24,
    InitArray = 25,
    FiniArray = 26,
    InitArraySz = 27,
    FiniArraySz = 28,
    Runpath = 29,
    Flags = 30,
    PreinitArray = 32,
    PreinitArraySz = 33,
    SymTabShndx = 34,
    RelrSz = 35,
    Relr = 36,
    RelrEnt = 37,
    AndroidRel = 0x6000000f,
    AndroidRelSz = 0x60000010,
    AndroidRela = 0x60000011,
    AndroidRelaSz = 0x60000012,
    AndroidRelr = 0x6fffe000,
    AndroidRelrSz = 0x6fffe001,
    AndroidRelrEnt = 0x6fffe003,
    GnuPrelinked = 0x6ffffdf5,
    GnuConflictSz = 0x6ffffdf6,
    GnuLiblistSz = 0x6ffffdf7,
    Checksum = 0x6ffffdf8,
    PltPadSz = 0x6ffffdf9,
    MoveEnt = 0x6ffffdfa,
    MoveSz = 0x6ffffdfb,
    Feature1 = 0x6ffffdfc,
    PosFlag1 = 0x6ffffdfd,
    SymInSz = 0x6ffffdfe,
    SymInEnt = 0x6ffffdff,
    GnuHash = 0x6ffffef5,
    TlsDescPlt = 0x6ffffef6,
    TlsDescGot = 0x6ffffef7,
    GnuConflict = 0x6ffffef8,
    GnuLiblist = 0x6ffffef9,
    Config = 0x6ffffefa,
    DepAudit = 0x6ffffefb,
    Audit = 0x6ffffefc,
    PltPad = 0x6ffffefd,
    MoveTab = 0x6ffffefe,
    SymInfo = 0x6ffffeff,
    VerSym = 0x6ffffff0,
    RelaCount = 0x6ffffff9,
    RelCount = 0x6ffffffa,
    Flags1 = 0x6ffffffb,
    VerDef = 0x6ffffffc,
    VerDefNum = 0x6ffffffd,
    VerNeed = 0x6ffffffe,
    VerNeedNum = 0x6fffffff,
    Auxiliary = 0x7ffffffd,
    Filter = 0x7fffffff,
    OsSpecific = 0x6000000d ... 0x6ffff000,
    ProcessorSpecific = 0x70000000 ... 0x7fffffff,
};

fn describeDynamicFlags(u64 flags) {
    str names = "";
    names = names + flagName(flags, 0x01, "origin");
    names = names + flagName(flags, 0x02, "symbolic");
    names = names + flagName(flags, 0x04, "textrel");
    names = names + flagName(flags, 0x08, "bind_now");
    names = names + flagName(flags, 0x10, "static_tls");
    return flagList(names);
};

fn describeDynamicFlags1(u64 flags) {
    str names = "";
    names = names + flagName(flags, 0x00000001, "now");
    names = names + flagName(flags, 0x00000002, "global");
    names = names + flagName(flags, 0x00000004, "group");
    names = names + flagName(flags, 0x00000008, "nodelete");
    names = names + flagName(flags, 0x00000010, "loadfltr");
    names = names + flagName(flags, 0x00000020, "initfirst");
    names = names + flagName(flags, 0x00000040, "noopen");
    names = names + flagName(flags, 0x00000080, "origin");
    names = names + flagName(flags, 0x00000100, "direct");
    names = names + flagName(flags, 0x00000200, "trans");
    names = names + flagName(flags, 0x00000400, "interpose");
    names = names + flagName(flags, 0x00000800, "nodeflib");
    names = names + flagName(flags, 0x00001000, "nodump");
    names = names + flagName(flags, 0x00002000, "confalt");
    names = names + flagName(flags, 0x00004000, "endfiltee");
    names = names + flagName(flags, 0x00008000, "dispreldne");
    names = names + flagName(flags, 0x00010000, "disprelpnd");
    names = names + flagName(flags, 0x00020000, "nodirect");
    names = names + flagName(flags, 0x00040000, "ignmuldef");
    names = names + flagName(flags, 0x00080000, "noksyms");
    names = names + flagName(flags, 0x00100000, "nohdr");
    names = names + flagName(flags, 0x00200000, "edited");
    names = names + flagName(flags, 0x00400000, "noreloc");
    names = names + flagName(flags, 0x00800000, "symintpose");
    names = names + flagName(flags, 0x01000000, "globaudit");
    names = names + flagName(flags, 0x02000000, "singleton");
    names = names + flagName(flags, 0x04000000, "stub");
    names = names + flagName(flags, 0x08000000, "pie");
    names = names + flagName(flags, 0x10000000, "kmod");
    names = names + flagName(flags, 0x20000000, "weakfilter");
    names = names + flagName(flags, 0x40000000, "nocommon");
    return flagList(names);
};

fn describeDynamicPositionalFlags(u64 flags) {
    str names = "";
    names = names + flagName(flags, 0x01, "lazyload");
    names = names + flagName(flags, 0x02, "groupperm");
    return flagList(names);
};

fn describeDynamicFeatures(u64 flags) {
    str names = "";
    names = names + flagName(flags, 0x01, "parinit");
    names = names + flagName(flags, 0x02, "confexp");
    return flagList(names);
};

struct DynamicSection<Addr, auto Size> {
    u64 imageStart = parent.imageStart;
    Machine machine = parent.machine;
    u64 count = Size / (2 * sizeof(Addr));
    u64 entrySize = 2 * sizeof(Addr);
    u64 stringTable = dataOffsetOfAddress(imageStart, dynamicValue($, count, entrySize, DynamicTagValue::StrTab));
    u64 symbolTable = dataOffsetOfAddress(imageStart, dynamicValue($, count, entrySize, DynamicTagValue::SymTab));
    u64 symbolStrings = stringTable;
    DynamicEntry<Addr> entries[count];
    u64 base = addressof(entries);
    u64 symbolCount = dynamicSymbolCount(imageStart, base, count, entrySize);
    if (dynamicValue(base, count, entrySize, DynamicTagValue::SymTab) != 0) {
        SymbolTable<Addr, symbolCount> symbols @ symbolTable;
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::StrTab) != 0) {
        CString strings[while($ < stringTable + dynamicValue(base, count, entrySize, DynamicTagValue::StrSz))] @ stringTable;
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::Rela) != 0) {
        u64 relaSize = dynamicValue(base, count, entrySize, DynamicTagValue::RelaSz);
        u64 relaEntry = dynamicValue(base, count, entrySize, DynamicTagValue::RelaEnt);
        Relocation<Addr, true> rela[relaSize / relaEntry]
            @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::Rela));
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::Rel) != 0) {
        u64 relSize = dynamicValue(base, count, entrySize, DynamicTagValue::RelSz);
        u64 relEntry = dynamicValue(base, count, entrySize, DynamicTagValue::RelEnt);
        Relocation<Addr, false> rel[relSize / relEntry]
            @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::Rel));
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::JmpRel) != 0) {
        if (dynamicValue(base, count, entrySize, DynamicTagValue::PltRel) == DynamicTagValue::Rela) {
            Relocation<Addr, true> plt_relocations[dynamicValue(base, count, entrySize, DynamicTagValue::PltRelSz) / (3 * sizeof(Addr))]
                @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::JmpRel));
        } else {
            Relocation<Addr, false> plt_relocations[dynamicValue(base, count, entrySize, DynamicTagValue::PltRelSz) / (2 * sizeof(Addr))]
                @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::JmpRel));
        }
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::Relr) != 0) {
        RelativeRelocation<Addr> relr[dynamicValue(base, count, entrySize, DynamicTagValue::RelrSz) / sizeof(Addr)]
            @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::Relr));
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::PreinitArray) != 0) {
        Addr preinit_array[dynamicValue(base, count, entrySize, DynamicTagValue::PreinitArraySz) / sizeof(Addr)]
            @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::PreinitArray));
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::InitArray) != 0) {
        Addr init_array[dynamicValue(base, count, entrySize, DynamicTagValue::InitArraySz) / sizeof(Addr)]
            @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::InitArray));
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::FiniArray) != 0) {
        Addr fini_array[dynamicValue(base, count, entrySize, DynamicTagValue::FiniArraySz) / sizeof(Addr)]
            @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::FiniArray));
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::GnuHash) != 0) {
        GnuHashTable<Addr> gnu_hash @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::GnuHash));
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::Hash) != 0) {
        SysvHash hash @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::Hash));
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::VerSym) != 0) {
        VersionIndex versions[symbolCount] @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::VerSym));
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::VerDef) != 0) {
        VersionDefinition definitions[dynamicValue(base, count, entrySize, DynamicTagValue::VerDefNum)]
            @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::VerDef));
    }
    if (dynamicValue(base, count, entrySize, DynamicTagValue::VerNeed) != 0) {
        VersionRequirement requirements[dynamicValue(base, count, entrySize, DynamicTagValue::VerNeedNum)]
            @ dataOffsetOfAddress(imageStart, dynamicValue(base, count, entrySize, DynamicTagValue::VerNeed));
    }
    str summary = std::format("{} entries, {} symbols", count, symbolCount);
} [[format("summaryOf")]];

struct GnuHashTable<Addr> {
    u32 nbuckets;
    u32 symoffset;
    u32 bloom_size;
    u32 bloom_shift;
    Addr bloom[bloom_size];
    u32 buckets[nbuckets];
    u32 chains[parent.symbolCount - symoffset];
    str summary = std::format("{} buckets, symbols from {}", nbuckets, symoffset);
} [[format("summaryOf")]];

fn dynamicValue(u64 entries, u64 count, u64 entrySize, u64 tag) {
    for (u64 i = 0, i < count, i = i + 1) {
        if (std::mem::read_unsigned(entries + i * entrySize, entrySize / 2) == tag) {
            return std::mem::read_unsigned(entries + i * entrySize + entrySize / 2, entrySize / 2);
        }
    }
    return 0;
};

fn dynamicSymbolCount(u64 imageStart, u64 entries, u64 count, u64 entrySize) {
    u64 sysvHash = dynamicValue(entries, count, entrySize, DynamicTagValue::Hash);
    if (sysvHash != 0) {
        return std::mem::read_unsigned(dataOffsetOfAddress(imageStart, sysvHash) + 4, 4);
    }
    u64 gnuHash = dynamicValue(entries, count, entrySize, DynamicTagValue::GnuHash);
    if (gnuHash != 0) {
        return gnuHashSymbolCount(dataOffsetOfAddress(imageStart, gnuHash), entrySize / 2);
    }
    return 0;
};

fn gnuHashSymbolCount(u64 table, u64 wordSize) {
    u32 nbuckets = std::mem::read_unsigned(table, 4);
    u32 symoffset = std::mem::read_unsigned(table + 4, 4);
    u32 bloomSize = std::mem::read_unsigned(table + 8, 4);
    u64 buckets = table + 16 + bloomSize * wordSize;
    u64 chains = buckets + nbuckets * 4;
    u32 last = 0;
    for (u32 i = 0, i < nbuckets, i = i + 1) {
        u32 index = std::mem::read_unsigned(buckets + i * 4, 4);
        if (index > last) {
            last = index;
        }
    }
    if (last < symoffset) {
        return symoffset;
    }
    while ((std::mem::read_unsigned(chains + (last - symoffset) * 4, 4) & 1) == 0) {
        last = last + 1;
    }
    return last + 1;
};

struct VersionIndex {
    u16 value [[format("formatVersionIndex")]];
    str summary = formatVersionIndex(value);
} [[format("summaryOf")]];

fn formatVersionIndex(u16 value) {
    match (value & 0x7fff) {
        (0): return "local";
        (1): return "global";
        (_): return std::format("version {}{}", value & 0x7fff, (value & 0x8000) != 0 ? " (hidden)" : "");
    }
};

struct VersionDefinition {
    u16 vd_version;
    u16 vd_flags [[format("describeVersionFlags")]];
    u16 vd_ndx;
    u16 vd_cnt;
    u32 vd_hash;
    u32 vd_aux;
    u32 vd_next;
    VersionDefinitionAux aux[vd_cnt] @ addressof(this) + vd_aux;
    if (vd_next != 0) {
        $ = addressof(this) + vd_next;
    }
    str summary = std::format("{} {} ({})", vd_ndx, aux[0].name, describeVersionFlags(vd_flags));
} [[format("summaryOf")]];

fn describeVersionFlags(u16 flags) {
    str names = "";
    names = names + flagName(flags, 0x1, "base");
    names = names + flagName(flags, 0x2, "weak");
    names = names + flagName(flags, 0x4, "info");
    return flagList(names);
};

struct VersionDefinitionAux {
    u32 vda_name;
    u32 vda_next;
    char name[] @ parent.parent.stringTable + vda_name;
    if (vda_next != 0) {
        $ = addressof(this) + vda_next;
    }
    str summary = name;
} [[format("summaryOf")]];

struct VersionRequirement {
    u16 vn_version;
    u16 vn_cnt;
    u32 vn_file;
    u32 vn_aux;
    u32 vn_next;
    char file[] @ parent.stringTable + vn_file;
    VersionRequirementAux aux[vn_cnt] @ addressof(this) + vn_aux;
    if (vn_next != 0) {
        $ = addressof(this) + vn_next;
    }
    str summary = std::format("{} ({} versions)", file, vn_cnt);
} [[format("summaryOf")]];

struct VersionRequirementAux {
    u32 vna_hash;
    u16 vna_flags [[format("describeVersionFlags")]];
    u16 vna_other;
    u32 vna_name;
    u32 vna_next;
    char name[] @ parent.parent.stringTable + vna_name;
    if (vna_next != 0) {
        $ = addressof(this) + vna_next;
    }
    str summary = std::format("{} {}", vna_other, name);
} [[format("summaryOf")]];

struct NoteList<Addr, auto Size> {
    Note<Addr> notes[while($ < addressof(this) + Size)];
    str summary = std::format("{} notes", std::core::member_count(notes));
} [[format("summaryOf")]];

struct Note<Addr> {
    u32 n_namesz;
    u32 n_descsz;
    str owner = std::mem::read_string($ + 4, n_namesz > 0 ? n_namesz - 1 : 0);
    u32 typeValue = std::mem::read_unsigned($, 4);
    if (owner == "GNU") {
        GnuNoteType n_type;
    } else if (owner == "Android") {
        AndroidNoteType n_type;
    } else if (owner == "CORE" || owner == "LINUX") {
        CoreNoteType n_type;
    } else if (owner == "FreeBSD") {
        FreeBsdNoteType n_type;
    } else {
        u32 n_type;
    }
    char name[n_namesz];
    padding[alignmentPadding(n_namesz, 4)];
    u64 descriptor = $;
    if (owner == "GNU" && typeValue == GnuNoteType::AbiTag) {
        GnuAbiTag desc;
    } else if (owner == "GNU" && typeValue == GnuNoteType::BuildId) {
        u8 desc[n_descsz] [[format("formatHex")]];
    } else if (owner == "GNU" && typeValue == GnuNoteType::GoldVersion) {
        char desc[n_descsz];
    } else if (owner == "GNU" && typeValue == GnuNoteType::PropertyType0) {
        PropertyList<Addr, n_descsz> desc;
    } else if (owner == "Android" && typeValue == AndroidNoteType::Ident) {
        AndroidIdent<n_descsz> desc;
    } else if (owner == "Android" && typeValue == AndroidNoteType::Memtag) {
        AndroidMemtag desc;
    } else if (owner == "FreeBSD" && typeValue == FreeBsdNoteType::AbiTag) {
        u32 desc;
    } else {
        u8 desc[n_descsz] [[sealed]];
    }
    padding[descriptor + n_descsz + alignmentPadding(n_descsz, 4) - $];
    str summary = std::format("{} {}", owner, noteTypeName(owner, typeValue));
} [[format("summaryOf")]];

fn noteTypeName(str owner, u32 type) {
    if (owner == "GNU") {
        match (type) {
            (1): return "AbiTag";
            (2): return "Hwcap";
            (3): return "BuildId";
            (4): return "GoldVersion";
            (5): return "PropertyType0";
        }
    } else if (owner == "Android") {
        match (type) {
            (1): return "Ident";
            (3): return "Kuser";
            (4): return "Memtag";
            (5): return "PadSegment";
        }
    } else if (owner == "FreeBSD") {
        match (type) {
            (1): return "AbiTag";
            (2): return "NoInitTag";
            (3): return "ArchTag";
            (4): return "FeatureCtl";
        }
    }
    return std::format("type {}", type);
};

enum GnuNoteType : u32 {
    AbiTag = 1,
    Hwcap = 2,
    BuildId = 3,
    GoldVersion = 4,
    PropertyType0 = 5,
};

enum AndroidNoteType : u32 {
    Ident = 1,
    Kuser = 3,
    Memtag = 4,
    PadSegment = 5,
};

enum CoreNoteType : u32 {
    PrStatus = 1,
    PrFpReg = 2,
    PrPsInfo = 3,
    TaskStruct = 4,
    Platform = 5,
    Auxv = 6,
    GWindows = 7,
    Asrs = 8,
    PStatus = 10,
    PsInfo = 13,
    PrCred = 14,
    UtsName = 15,
    LwpStatus = 16,
    LwpsInfo = 17,
    PrFpxReg = 20,
    SigInfo = 0x53494749,
    File = 0x46494c45,
    PrXfpReg = 0x46e62b7f,
    PpcVmx = 0x100,
    PpcSpe = 0x101,
    PpcVsx = 0x102,
    X86Tls = 0x200,
    X86IoPerm = 0x201,
    X86XState = 0x202,
    S390HighGprs = 0x300,
    S390Timer = 0x301,
    S390TodCmp = 0x302,
    S390TodPreg = 0x303,
    S390Ctrs = 0x304,
    S390Prefix = 0x305,
    S390LastBreak = 0x306,
    S390SystemCall = 0x307,
    S390Tdb = 0x308,
    ArmVfp = 0x400,
    ArmTls = 0x401,
    ArmHwBreak = 0x402,
    ArmHwWatch = 0x403,
    ArmSystemCall = 0x404,
    ArmSve = 0x405,
    ArmPacMask = 0x406,
    ArmPacaKeys = 0x407,
    ArmPacgKeys = 0x408,
    ArmTaggedAddrCtrl = 0x409,
    ArmSsve = 0x40b,
    ArmZa = 0x40c,
    ArmZt = 0x40d,
    ArmFpmr = 0x40e,
    ArmGcs = 0x410,
    VmCoreDd = 0x700,
    MipsDsp = 0x800,
    MipsFpMode = 0x801,
    MipsMsa = 0x802,
};

enum FreeBsdNoteType : u32 {
    AbiTag = 1,
    NoInitTag = 2,
    ArchTag = 3,
    FeatureCtl = 4,
};

struct GnuAbiTag {
    GnuAbiOs os;
    u32 major;
    u32 minor;
    u32 patch;
    str summary = std::format("{} {}.{}.{}", enumName(std::format("{}", os)), major, minor, patch);
} [[format("summaryOf")]];

enum GnuAbiOs : u32 {
    Linux = 0,
    Gnu = 1,
    Solaris2 = 2,
    FreeBsd = 3,
};

struct PropertyList<Addr, auto Size> {
    Property<Addr> properties[while($ < addressof(this) + Size)];
};

struct Property<Addr> {
    PropertyType pr_type;
    u32 pr_datasz;
    match (pr_type) {
        (PropertyType::StackSize): Addr stack_size;
        (PropertyType::NoCopyOnProtected): padding[0];
        (PropertyType::AArch64Feature1And): AArch64Features features;
        (PropertyType::X86Feature1And): X86Features features;
        (PropertyType::X86Isa1Used | PropertyType::X86Isa1Needed): X86IsaLevels levels;
        (PropertyType::X86Feature2Used | PropertyType::X86Feature2Needed): X86Features2 features;
        (_): u8 data[pr_datasz] [[sealed]];
    }
    padding[alignmentPadding(pr_datasz, sizeof(Addr))];
    str summary = enumName(std::format("{}", pr_type));
} [[format("summaryOf")]];

enum PropertyType : u32 {
    StackSize = 1,
    NoCopyOnProtected = 2,
    AArch64Feature1And = 0xc0000000,
    AArch64FeaturePauth = 0xc0000001,
    X86Feature1And = 0xc0000002,
    X86Feature2Needed = 0xc0008001,
    X86Isa1Needed = 0xc0008002,
    X86Feature2Used = 0xc0010001,
    X86Isa1Used = 0xc0010002,
    ProcessorSpecific = 0xc0000000 ... 0xdfffffff,
    UserSpecific = 0xe0000000 ... 0xffffffff,
};

bitfield AArch64Features {
    bool bti : 1;
    bool pac : 1;
    bool gcs : 1;
    padding : 29;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

bitfield X86Features {
    bool ibt : 1;
    bool shstk : 1;
    padding : 30;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

bitfield X86Features2 {
    bool x86 : 1;
    bool x87 : 1;
    bool mmx : 1;
    bool xmm : 1;
    bool ymm : 1;
    bool zmm : 1;
    bool fxsr : 1;
    bool xsave : 1;
    bool xsaveopt : 1;
    bool xsavec : 1;
    padding : 22;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

bitfield X86IsaLevels {
    bool baseline : 1;
    bool v2 : 1;
    bool v3 : 1;
    bool v4 : 1;
    padding : 28;
} [[bitfield_order(std::core::BitfieldOrder::LeastToMostSignificant, 32)]];

struct AndroidIdent<auto Size> {
    u32 android_api;
    if (Size > 4) {
        char ndk_version[64];
        char ndk_build_number[64];
        str summary = std::format("API {} NDK {} build {}", android_api, ndk_version, ndk_build_number);
    } else {
        str summary = std::format("API {}", android_api);
    }
} [[format("summaryOf")]];

struct AndroidMemtag {
    u32 value [[format("describeAndroidMemtag")]];
    str summary = describeAndroidMemtag(value);
} [[format("summaryOf")]];

fn describeAndroidMemtag(u32 value) {
    str names = "";
    match (value & 3) {
        (0): names = names + ", none";
        (1): names = names + ", async";
        (2): names = names + ", sync";
        (3): names = names + ", asymm";
    }
    names = names + flagName(value, 4, "heap");
    names = names + flagName(value, 8, "stack");
    return flagList(names);
};

struct EhFrameHeader<Addr> {
    u8 version;
    PointerEncoding eh_frame_ptr_enc;
    PointerEncoding fde_count_enc;
    PointerEncoding table_enc;
    EncodedPointer<Addr, eh_frame_ptr_enc.format> eh_frame_ptr;
    EncodedPointer<Addr, fde_count_enc.format> fde_count;
    if (table_enc.format == PointerFormat::Sdata4 || table_enc.format == PointerFormat::Udata4) {
        EhFrameTableEntry<s32> table[fde_count.value];
    } else if (table_enc.format == PointerFormat::Sdata8 || table_enc.format == PointerFormat::Udata8) {
        EhFrameTableEntry<s64> table[fde_count.value];
    }
    str summary = std::format("version {}, {} FDEs", version, fde_count.value);
} [[format("summaryOf")]];

bitfield PointerEncoding {
    PointerFormat format : 4;
    PointerApplication application : 3;
    bool indirect : 1;
};

enum PointerFormat : u8 {
    Absolute = 0x0,
    Uleb128 = 0x1,
    Udata2 = 0x2,
    Udata4 = 0x3,
    Udata8 = 0x4,
    Sleb128 = 0x9,
    Sdata2 = 0xa,
    Sdata4 = 0xb,
    Sdata8 = 0xc,
    Omit = 0xf,
};

enum PointerApplication : u8 {
    Absolute = 0,
    PcRelative = 1,
    TextRelative = 2,
    DataRelative = 3,
    FunctionRelative = 4,
    Aligned = 5,
};

struct EncodedPointer<Addr, auto Format> {
    match (Format) {
        (PointerFormat::Absolute): Addr value;
        (PointerFormat::Udata2): u16 value;
        (PointerFormat::Udata4): u32 value;
        (PointerFormat::Udata8): u64 value;
        (PointerFormat::Sdata2): s16 value;
        (PointerFormat::Sdata4): s32 value;
        (PointerFormat::Sdata8): s64 value;
        (_): u8 value[0];
    }
};

struct EhFrameTableEntry<T> {
    T initial_location;
    T address;
};

struct SectionGroup<auto Size> {
    u32 flags [[format("describeGroupFlags")]];
    u32 sections[(Size - 4) / 4];
};

fn describeGroupFlags(u32 flags) {
    return flagList(flagName(flags, 0x1, "comdat"));
};

struct BuildAttributes<auto Size> {
    char format_version;
    AttributeSection sections[while($ < addressof(this) + Size)];
};

struct AttributeSection {
    u32 length;
    char vendor[];
    AttributeSubsection subsections[while($ < addressof(this) + length)];
    str summary = vendor;
} [[format("summaryOf")]];

struct AttributeSubsection {
    AttributeScope tag;
    u32 size;
    u8 attributes[size - 5] [[sealed]];
    str summary = enumName(std::format("{}", tag));
} [[format("summaryOf")]];

enum AttributeScope : u8 {
    File = 1,
    Section = 2,
    Symbol = 3,
};

struct ArmExceptionIndex<auto Size> {
    ArmExceptionIndexEntry entries[Size / 8];
};

struct ArmExceptionIndexEntry {
    u32 function [[format("formatPrel31")]];
    u32 content [[format("formatArmExceptionContent")]];
    str summary = formatArmExceptionContent(content);
} [[format("summaryOf")]];

fn formatPrel31(u32 value) {
    s32 offset = value & 0x7fffffff;
    if ((value & 0x40000000) != 0) {
        offset = offset - 0x80000000;
    }
    return std::format("{:+}", offset);
};

fn formatArmExceptionContent(u32 content) {
    if (content == 1) {
        return "cannot unwind";
    }
    if ((content & 0x80000000) != 0) {
        return std::format("inline personality {}", (content >> 24) & 0xf);
    }
    return std::format("extab {}", formatPrel31(content));
};

struct MipsAbiFlags {
    u16 version;
    u8 isa_level;
    u8 isa_rev;
    MipsRegisterSize gpr_size;
    MipsRegisterSize cpr1_size;
    MipsRegisterSize cpr2_size;
    MipsFpAbi fp_abi;
    u32 isa_ext;
    u32 ases [[format("describeMipsAses")]];
    u32 flags1 [[format("describeMipsFlags1")]];
    u32 flags2;
    str summary = std::format("MIPS{} r{} {}", isa_level, isa_rev, enumName(std::format("{}", fp_abi)));
} [[format("summaryOf")]];

enum MipsRegisterSize : u8 {
    None = 0,
    Bits32 = 1,
    Bits64 = 2,
    Bits128 = 3,
};

enum MipsFpAbi : u8 {
    Any = 0,
    Double = 1,
    Single = 2,
    Soft = 3,
    Old64 = 4,
    Xx = 5,
    Bits64 = 6,
    Bits64A = 7,
};

fn describeMipsAses(u32 ases) {
    str names = "";
    names = names + flagName(ases, 0x0001, "DSP");
    names = names + flagName(ases, 0x0002, "DSPR2");
    names = names + flagName(ases, 0x0004, "EVA");
    names = names + flagName(ases, 0x0008, "MCU");
    names = names + flagName(ases, 0x0010, "MDMX");
    names = names + flagName(ases, 0x0020, "MIPS3D");
    names = names + flagName(ases, 0x0040, "MT");
    names = names + flagName(ases, 0x0080, "SmartMIPS");
    names = names + flagName(ases, 0x0100, "VZ");
    names = names + flagName(ases, 0x0200, "MSA");
    names = names + flagName(ases, 0x0400, "MIPS16");
    names = names + flagName(ases, 0x0800, "microMIPS");
    names = names + flagName(ases, 0x1000, "XPA");
    return flagList(names);
};

fn describeMipsFlags1(u32 flags) {
    return flagList(flagName(flags, 0x1, "odd single-precision registers"));
};

struct MipsRegisterInfo<Addr> {
    u32 ri_gprmask;
    if (sizeof(Addr) == 8) {
        u32 ri_pad;
    }
    u32 ri_cprmask[4];
    if (sizeof(Addr) == 8) {
        s64 ri_gp_value;
    } else {
        s32 ri_gp_value;
    }
};

fn alignmentPadding(u64 size, u64 alignment) {
    return (alignment - (size % alignment)) % alignment;
};

fn formatHex(ref auto bytes) {
    str text = "";
    for (u32 i = 0, i < sizeof(bytes), i = i + 1) {
        text = text + std::format("{:02x}", bytes[i]);
    }
    return text;
};

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

fn flagName(u64 flags, u64 mask, str name) {
    return (flags & mask) != 0 ? ", " + name : "";
};

fn flagList(str names) {
    if (names == "") {
        return "none";
    }
    return std::string::substr(names, 2, std::string::length(names) - 2);
};

fn sectionOffset(u64 imageStart, u64 index) {
    return std::mem::read_unsigned(sectionHeader(imageStart, index) + (is64Bit(imageStart) ? 0x18 : 0x10), is64Bit(imageStart) ? 8 : 4);
};

fn sectionSize(u64 imageStart, u64 index) {
    return std::mem::read_unsigned(sectionHeader(imageStart, index) + (is64Bit(imageStart) ? 0x20 : 0x14), is64Bit(imageStart) ? 8 : 4);
};

fn sectionLink(u64 imageStart, u64 index) {
    return std::mem::read_unsigned(sectionHeader(imageStart, index) + (is64Bit(imageStart) ? 0x28 : 0x18), 4);
};

fn sectionInfo(u64 imageStart, u64 index) {
    return std::mem::read_unsigned(sectionHeader(imageStart, index) + (is64Bit(imageStart) ? 0x2c : 0x1c), 4);
};

fn sectionHeader(u64 imageStart, u64 index) {
    u64 tableOffset = std::mem::read_unsigned(imageStart + (is64Bit(imageStart) ? 0x28 : 0x20), is64Bit(imageStart) ? 8 : 4);
    u64 entrySize = std::mem::read_unsigned(imageStart + (is64Bit(imageStart) ? 0x3a : 0x2e), 2);
    return dataOffsetOf(imageStart, tableOffset + index * entrySize);
};

fn is64Bit(u64 imageStart) {
    return std::mem::read_unsigned(imageStart + 4, 1) == Class::Elf64;
};

#ifdef __MEMORY__
fn dataOffsetOf(u64 imageStart, u64 fileOffset) {
    LoadSegment segment = loadSegmentContainingOffset(imageStart, fileOffset);
    return imageStart + (segment.address - loadBaseAddress(imageStart)) + (fileOffset - segment.offset);
};

fn dataOffsetOfAddress(u64 imageStart, u64 address) {
    return imageStart + (address - loadBaseAddress(imageStart));
};

fn fileOffsetIsMapped(u64 imageStart, u64 fileOffset) {
    LoadSegment segment = loadSegmentContainingOffset(imageStart, fileOffset);
    return segment.size > 0;
};
#else
fn dataOffsetOf(u64 imageStart, u64 fileOffset) {
    return imageStart + fileOffset;
};

fn dataOffsetOfAddress(u64 imageStart, u64 address) {
    LoadSegment segment = loadSegmentContainingAddress(imageStart, address);
    return imageStart + segment.offset + (address - segment.address);
};

fn fileOffsetIsMapped(u64 imageStart, u64 fileOffset) {
    return true;
};
#endif

struct LoadSegment {
    u64 address;
    u64 offset;
    u64 size;
};

fn loadSegmentContainingOffset(u64 imageStart, u64 fileOffset) {
    LoadSegment found;
    ProgramHeaderTable table = programHeaderTable(imageStart);
    for (u64 i = 0, i < table.count, i = i + 1) {
        LoadSegment segment = loadSegment(table, i);
        if (segment.size > 0 && fileOffset >= segment.offset && fileOffset < segment.offset + segment.size) {
            return segment;
        }
    }
    return found;
};

fn loadSegmentContainingAddress(u64 imageStart, u64 address) {
    LoadSegment found;
    ProgramHeaderTable table = programHeaderTable(imageStart);
    for (u64 i = 0, i < table.count, i = i + 1) {
        LoadSegment segment = loadSegment(table, i);
        if (segment.size > 0 && address >= segment.address && address < segment.address + segment.size) {
            return segment;
        }
    }
    return found;
};

fn loadBaseAddress(u64 imageStart) {
    u64 base = 0;
    bool seen = false;
    ProgramHeaderTable table = programHeaderTable(imageStart);
    for (u64 i = 0, i < table.count, i = i + 1) {
        LoadSegment segment = loadSegment(table, i);
        if (segment.size > 0 && (!seen || segment.address < base)) {
            base = segment.address;
            seen = true;
        }
    }
    return base - (base % 0x1000);
};

struct ProgramHeaderTable {
    u64 start;
    u64 count;
    u64 entrySize;
    bool wide;
};

fn programHeaderTable(u64 imageStart) {
    ProgramHeaderTable table;
    table.wide = is64Bit(imageStart);
    table.start = imageStart + std::mem::read_unsigned(imageStart + (table.wide ? 0x20 : 0x1c), table.wide ? 8 : 4);
    table.entrySize = std::mem::read_unsigned(imageStart + (table.wide ? 0x36 : 0x2a), 2);
    table.count = std::mem::read_unsigned(imageStart + (table.wide ? 0x38 : 0x2c), 2);
    return table;
};

fn loadSegment(ProgramHeaderTable table, u64 index) {
    LoadSegment segment;
    u64 header = table.start + index * table.entrySize;
    if (std::mem::read_unsigned(header, 4) != SegmentType::Load) {
        return segment;
    }
    if (table.wide) {
        segment.offset = std::mem::read_unsigned(header + 8, 8);
        segment.address = std::mem::read_unsigned(header + 16, 8);
        segment.size = std::mem::read_unsigned(header + 32, 8);
    } else {
        segment.offset = std::mem::read_unsigned(header + 4, 4);
        segment.address = std::mem::read_unsigned(header + 8, 4);
        segment.size = std::mem::read_unsigned(header + 16, 4);
    }
    return segment;
};
