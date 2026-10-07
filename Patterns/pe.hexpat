import std.core;
import std.mem;
import std.string;

PortableExecutable pe @ 0x00;

struct PortableExecutable {
    std::core::set_endian(std::mem::Endian::Little);
    u64 imageStart = addressof(this);
    if (std::mem::read_unsigned($, 2) == 0x5a4d) {
        DosHeader dos;
        DosStub stub;
        NtHeaders nt @ imageStart + dos.e_lfanew;
        str summary = std::core::formatted_value(nt);
    } else {
        CoffObject object [[inline]];
        str summary = std::core::formatted_value(object);
    }
} [[format("summaryOf")]];

struct CoffObject {
    u64 imageStart = parent.imageStart;
    FileHeader FileHeader;
    SectionHeader sections[FileHeader.NumberOfSections] @ addressof(FileHeader) + 20 + FileHeader.SizeOfOptionalHeader;
    str summary = std::core::formatted_value(FileHeader);
} [[format("summaryOf")]];

struct DosHeader {
    char e_magic[2];
    u16 e_cblp;
    u16 e_cp;
    u16 e_crlc;
    u16 e_cparhdr;
    u16 e_minalloc;
    u16 e_maxalloc;
    u16 e_ss;
    u16 e_sp;
    u16 e_csum;
    u16 e_ip;
    u16 e_cs;
    u16 e_lfarlc;
    u16 e_ovno;
    u16 e_res[4];
    u16 e_oemid;
    u16 e_oeminfo;
    u16 e_res2[10];
    u32 e_lfanew;
    str summary = std::format("PE header at {:#x}", e_lfanew);
} [[format("summaryOf")]];

struct DosStub {
    u64 end = parent.imageStart + parent.dos.e_lfanew;
    s128 richEnd = std::mem::find_sequence_in_range(0, $, end, 0x52, 0x69, 0x63, 0x68);
    if (richEnd >= 0) {
        u8 program[richHeaderStart($, richEnd) - $];
        RichHeader rich;
        padding[end - $];
    } else {
        u8 program[end - $];
    }
};

fn richHeaderStart(u64 stubStart, u64 richEnd) {
    u32 key = std::mem::read_unsigned(richEnd + 4, 4);
    u64 position = richEnd - 8;
    while (position > stubStart && (std::mem::read_unsigned(position, 4) ^ key) != 0x536e6144) {
        position = position - 8;
    }
    return position;
};

struct RichHeader {
    u64 richEnd = parent.richEnd;
    u32 key = std::mem::read_unsigned(richEnd + 4, 4);
    u32 dans [[format("formatRichMarker")]];
    u32 pad[3];
    RichEntry entries[(richEnd - $) / 8];
    char rich[4];
    u32 xorKey;
    str summary = std::format("{} tool records", std::core::member_count(entries));
} [[format("summaryOf")]];

fn formatRichMarker(u32 masked) {
    return "DanS";
};

struct RichEntry {
    u32 maskedComponent;
    u32 maskedUses;
    u16 buildNumber = (maskedComponent ^ parent.key) & 0xffff [[export]];
    u16 productId = (maskedComponent ^ parent.key) >> 16 [[export]];
    u32 uses = maskedUses ^ parent.key [[export]];
    str summary = std::format("product {:#x} build {} used {} times", productId, buildNumber, uses);
} [[format("summaryOf")]];

struct NtHeaders {
    u64 imageStart = parent.imageStart;
    char Signature[4];
    FileHeader FileHeader;
    match (std::mem::read_unsigned($, 2)) {
        (OptionalMagic::Pe32Plus): OptionalHeader<u64> OptionalHeader;
        (_): OptionalHeader<u32> OptionalHeader;
    }
    SectionHeader sections[FileHeader.NumberOfSections] @ addressof(OptionalHeader) + FileHeader.SizeOfOptionalHeader;
    str summary = std::core::formatted_value(FileHeader);
} [[format("summaryOf")]];

struct FileHeader {
    u64 imageStart = parent.imageStart;
    Machine Machine;
    u16 NumberOfSections;
    u32 TimeDateStamp [[hex::inline_visualize("timestamp", this)]];
    u32 PointerToSymbolTable;
    u32 NumberOfSymbols;
    u16 SizeOfOptionalHeader;
    FileCharacteristics Characteristics;
    if (PointerToSymbolTable != 0 && NumberOfSymbols != 0 && fileOffsetIsMapped()) {
        CoffSymbolTable symbols @ imageStart + PointerToSymbolTable;
    }
    str summary = std::format("{} {}", enumName(std::format("{}", Machine)),
        Characteristics.dll ? "DLL" : (Characteristics.executable_image ? "executable" : "object"));
} [[format("summaryOf")]];

enum Machine : u16 {
    Unknown = 0x0,
    I386 = 0x14c,
    R3000 = 0x162,
    R4000 = 0x166,
    R10000 = 0x168,
    WceMipsV2 = 0x169,
    Alpha = 0x184,
    Sh3 = 0x1a2,
    Sh3Dsp = 0x1a3,
    Sh3E = 0x1a4,
    Sh4 = 0x1a6,
    Sh5 = 0x1a8,
    Arm = 0x1c0,
    Thumb = 0x1c2,
    ArmNt = 0x1c4,
    Am33 = 0x1d3,
    PowerPc = 0x1f0,
    PowerPcFp = 0x1f1,
    Ia64 = 0x200,
    Mips16 = 0x266,
    Alpha64 = 0x284,
    MipsFpu = 0x366,
    MipsFpu16 = 0x466,
    Tricore = 0x520,
    Cef = 0xcef,
    Ebc = 0xebc,
    ChpeX86 = 0x3a64,
    RiscV32 = 0x5032,
    RiscV64 = 0x5064,
    RiscV128 = 0x5128,
    LoongArch32 = 0x6232,
    LoongArch64 = 0x6264,
    Amd64 = 0x8664,
    M32R = 0x9041,
    Arm64Ec = 0xa641,
    Arm64X = 0xa64e,
    Arm64 = 0xaa64,
    Cee = 0xc0ee,
};

bitfield FileCharacteristics {
    bool relocs_stripped : 1;
    bool executable_image : 1;
    bool line_nums_stripped : 1;
    bool local_syms_stripped : 1;
    bool aggressive_ws_trim : 1;
    bool large_address_aware : 1;
    padding : 1;
    bool bytes_reversed_lo : 1;
    bool machine_32bit : 1;
    bool debug_stripped : 1;
    bool removable_run_from_swap : 1;
    bool net_run_from_swap : 1;
    bool system : 1;
    bool dll : 1;
    bool up_system_only : 1;
    bool bytes_reversed_hi : 1;
};

struct OptionalHeader<Addr> {
    u64 imageStart = parent.imageStart;
    Machine machine = parent.FileHeader.Machine;
    OptionalMagic Magic;
    u8 MajorLinkerVersion;
    u8 MinorLinkerVersion;
    u32 SizeOfCode;
    u32 SizeOfInitializedData;
    u32 SizeOfUninitializedData;
    u32 AddressOfEntryPoint;
    u32 BaseOfCode;
    if (sizeof(Addr) == 4) {
        u32 BaseOfData;
    }
    Addr ImageBase;
    u32 SectionAlignment;
    u32 FileAlignment;
    u16 MajorOperatingSystemVersion;
    u16 MinorOperatingSystemVersion;
    u16 MajorImageVersion;
    u16 MinorImageVersion;
    u16 MajorSubsystemVersion;
    u16 MinorSubsystemVersion;
    u32 Win32VersionValue;
    u32 SizeOfImage;
    u32 SizeOfHeaders;
    u32 CheckSum;
    Subsystem Subsystem;
    DllCharacteristics DllCharacteristics;
    Addr SizeOfStackReserve;
    Addr SizeOfStackCommit;
    Addr SizeOfHeapReserve;
    Addr SizeOfHeapCommit;
    u32 LoaderFlags;
    u32 NumberOfRvaAndSizes;
    DataDirectories<Addr> DataDirectory;
    if (AddressOfEntryPoint != 0) {
        u64 entryAddress = ImageBase + AddressOfEntryPoint;
        str architecture = disassemblerArchitecture(machine);
        EntryPreview entry @ dataOffsetOfRva(imageStart, AddressOfEntryPoint);
    }
    str summary = std::format("{} {} entry {:#x} base {:#x}", enumName(std::format("{}", Magic)), enumName(std::format("{}", Subsystem)),
        ImageBase + AddressOfEntryPoint, ImageBase);
} [[format("summaryOf")]];

enum OptionalMagic : u16 {
    Rom = 0x107,
    Pe32 = 0x10b,
    Pe32Plus = 0x20b,
};

enum Subsystem : u16 {
    Unknown = 0,
    Native = 1,
    WindowsGui = 2,
    WindowsCui = 3,
    Os2Cui = 5,
    PosixCui = 7,
    NativeWindows = 8,
    WindowsCeGui = 9,
    EfiApplication = 10,
    EfiBootServiceDriver = 11,
    EfiRuntimeDriver = 12,
    EfiRom = 13,
    Xbox = 14,
    WindowsBootApplication = 16,
    XboxCodeCatalog = 17,
};

bitfield DllCharacteristics {
    padding : 5;
    bool high_entropy_va : 1;
    bool dynamic_base : 1;
    bool force_integrity : 1;
    bool nx_compat : 1;
    bool no_isolation : 1;
    bool no_seh : 1;
    bool no_bind : 1;
    bool appcontainer : 1;
    bool wdm_driver : 1;
    bool guard_cf : 1;
    bool terminal_server_aware : 1;
};

struct EntryPreview {
    u8 instructions[64] [[hex::inline_visualize("disassembler", this, parent.entryAddress, parent.architecture)]];
};

struct DataDirectories<Addr> {
    u64 imageStart = parent.imageStart;
    Machine machine = parent.machine;
    u64 imageBase = parent.ImageBase;
    u32 count = parent.NumberOfRvaAndSizes;
    if (count > 0) {
        DataDirectory<ExportTable> Export;
    }
    if (count > 1) {
        DataDirectory<ImportTable<Addr>> Import;
    }
    if (count > 2) {
        DataDirectory<ResourceTable> Resource;
    }
    if (count > 3) {
        DataDirectory<ExceptionTable> Exception;
    }
    if (count > 4) {
        CertificateDirectory Certificate;
    }
    if (count > 5) {
        DataDirectory<BaseRelocationTable> BaseRelocation;
    }
    if (count > 6) {
        DataDirectory<DebugTable> Debug;
    }
    if (count > 7) {
        DataDirectory<Bytes> Architecture;
    }
    if (count > 8) {
        DataDirectory<Bytes> GlobalPointer;
    }
    if (count > 9) {
        DataDirectory<TlsDirectory<Addr>> Tls;
    }
    if (count > 10) {
        DataDirectory<LoadConfigDirectory<Addr>> LoadConfig;
    }
    if (count > 11) {
        DataDirectory<BoundImportTable> BoundImport;
    }
    if (count > 12) {
        DataDirectory<ImportAddressTable<Addr>> ImportAddressTable;
    }
    if (count > 13) {
        DataDirectory<DelayImportTable<Addr>> DelayImport;
    }
    if (count > 14) {
        DataDirectory<ClrHeader> ClrRuntime;
    }
    if (count > 15) {
        DataDirectory<Bytes> Reserved;
    }
    if (count > 16) {
        DataDirectory<Bytes> extra[count - 16];
    }
};

struct DataDirectory<Table> {
    u64 imageStart = parent.imageStart;
    Machine machine = parent.machine;
    u64 imageBase = parent.imageBase;
    u32 VirtualAddress;
    u32 Size;
    if (VirtualAddress != 0 && Size != 0) {
        Table table @ dataOffsetOfRva(imageStart, VirtualAddress);
        str summary = std::format("{:#x} ({} bytes) {}", VirtualAddress, Size, std::core::formatted_value(table));
    } else {
        str summary = "absent";
    }
} [[format("summaryOf")]];

struct CertificateDirectory {
    u64 imageStart = parent.imageStart;
    u32 VirtualAddress;
    u32 Size;
    if (VirtualAddress != 0 && Size != 0 && fileOffsetIsMapped()) {
        WinCertificate certificates[while($ < imageStart + VirtualAddress + Size)] @ imageStart + VirtualAddress;
        str summary = std::format("{} certificates", std::core::member_count(certificates));
    } else {
        str summary = VirtualAddress != 0 ? std::format("{} bytes at file offset {:#x}", Size, VirtualAddress) : "absent";
    }
} [[format("summaryOf")]];

struct WinCertificate {
    u32 dwLength;
    CertificateRevision wRevision;
    CertificateType wCertificateType;
    u8 bCertificate[dwLength - 8] [[sealed]];
    padding[alignmentPadding(dwLength, 8)];
    str summary = std::format("{} ({} bytes)", enumName(std::format("{}", wCertificateType)), dwLength - 8);
} [[format("summaryOf")]];

enum CertificateRevision : u16 {
    Revision1_0 = 0x100,
    Revision2_0 = 0x200,
};

enum CertificateType : u16 {
    X509 = 1,
    PkcsSignedData = 2,
    Reserved1 = 3,
    TsStackSigned = 4,
};

struct Bytes {
    u8 data[parent.Size] [[sealed]];
    str summary = std::format("{} bytes", parent.Size);
} [[format("summaryOf")]];

struct ExportTable {
    u64 imageStart = parent.imageStart;
    u32 directoryStart = parent.VirtualAddress;
    u32 directoryEnd = parent.VirtualAddress + parent.Size;
    u32 Characteristics;
    u32 TimeDateStamp [[hex::inline_visualize("timestamp", this)]];
    u16 MajorVersion;
    u16 MinorVersion;
    u32 Name;
    u32 Base;
    u32 NumberOfFunctions;
    u32 NumberOfNames;
    u32 AddressOfFunctions;
    u32 AddressOfNames;
    u32 AddressOfNameOrdinals;
    char name[] @ dataOffsetOfRva(imageStart, Name);
    ExportAddress functions[NumberOfFunctions] @ dataOffsetOfRva(imageStart, AddressOfFunctions);
    ExportName names[NumberOfNames] @ dataOffsetOfRva(imageStart, AddressOfNames);
    u16 ordinals[NumberOfNames] @ dataOffsetOfRva(imageStart, AddressOfNameOrdinals);
    str summary = std::format("{} exports {} functions, {} named", name, NumberOfFunctions, NumberOfNames);
} [[format("summaryOf")]];

struct ExportAddress {
    u32 rva;
    if (rva >= parent.directoryStart && rva < parent.directoryEnd) {
        char forwarder[] @ dataOffsetOfRva(parent.imageStart, rva);
        str summary = std::format("forwarded to {}", forwarder);
    } else {
        str summary = std::format("{:#x}", rva);
    }
} [[format("summaryOf")]];

struct ExportName {
    u32 rva;
    char name[] @ dataOffsetOfRva(parent.imageStart, rva);
    str summary = name;
} [[format("summaryOf")]];

struct ImportTable<Addr> {
    u64 imageStart = parent.imageStart;
    ImportDescriptor<Addr> descriptors[while(std::mem::read_unsigned($ + 12, 4) != 0 || std::mem::read_unsigned($ + 16, 4) != 0)];
    str summary = std::format("{} modules", std::core::member_count(descriptors));
} [[format("summaryOf")]];

struct ImportDescriptor<Addr> {
    u64 imageStart = parent.imageStart;
    u32 OriginalFirstThunk;
    u32 TimeDateStamp [[hex::inline_visualize("timestamp", this)]];
    u32 ForwarderChain;
    u32 Name;
    u32 FirstThunk;
    char name[] @ dataOffsetOfRva(imageStart, Name);
    if (OriginalFirstThunk != 0) {
        ImportThunk<Addr> lookups[while(std::mem::read_unsigned($, sizeof(Addr)) != 0)] @ dataOffsetOfRva(imageStart, OriginalFirstThunk);
    }
    if (FirstThunk != 0) {
        ImportAddress<Addr> addresses[while(std::mem::read_unsigned($, sizeof(Addr)) != 0)] @ dataOffsetOfRva(imageStart, FirstThunk);
    }
    str summary = name;
} [[format("summaryOf")]];

struct ImportThunk<Addr> {
    u64 imageStart = parent.imageStart;
    Addr value;
    if ((value >> (sizeof(Addr) * 8 - 1)) != 0) {
        u16 ordinal = value & 0xffff [[export]];
        str summary = std::format("ordinal {}", ordinal);
    } else {
        ImportByName entry @ dataOffsetOfRva(imageStart, value);
        str summary = entry.Name;
    }
} [[format("summaryOf")]];

struct ImportByName {
    u16 Hint;
    char Name[];
};

#ifdef __MEMORY__
struct ImportAddress<Addr> {
    Addr address;
    str summary = std::format("{:#x}", address);
} [[format("summaryOf")]];
#else
struct ImportAddress<Addr> {
    u64 imageStart = parent.imageStart;
    ImportThunk<Addr> thunk [[inline]];
    str summary = std::core::formatted_value(thunk);
} [[format("summaryOf")]];
#endif

struct ImportAddressTable<Addr> {
    Addr entries[parent.Size / sizeof(Addr)];
    str summary = std::format("{} slots", parent.Size / sizeof(Addr));
} [[format("summaryOf")]];

struct DelayImportTable<Addr> {
    u64 imageStart = parent.imageStart;
    u64 imageBase = parent.imageBase;
    DelayImportDescriptor<Addr> descriptors[while(std::mem::read_unsigned($ + 4, 4) != 0)];
    str summary = std::format("{} modules", std::core::member_count(descriptors));
} [[format("summaryOf")]];

struct DelayImportDescriptor<Addr> {
    u64 imageStart = parent.imageStart;
    DelayImportAttributes Attributes;
    u32 DllNameRVA;
    u32 ModuleHandleRVA;
    u32 ImportAddressTableRVA;
    u32 ImportNameTableRVA;
    u32 BoundImportAddressTableRVA;
    u32 UnloadInformationTableRVA;
    u32 TimeDateStamp [[hex::inline_visualize("timestamp", this)]];
    u64 base = Attributes.rva_based ? 0 : parent.imageBase;
    char name[] @ dataOffsetOfRva(imageStart, DllNameRVA - base);
    if (ImportNameTableRVA != 0) {
        ImportThunk<Addr> names[while(std::mem::read_unsigned($, sizeof(Addr)) != 0)]
            @ dataOffsetOfRva(imageStart, ImportNameTableRVA - base);
    }
    if (ImportAddressTableRVA != 0) {
        Addr addresses[while(std::mem::read_unsigned($, sizeof(Addr)) != 0)] @ dataOffsetOfRva(imageStart, ImportAddressTableRVA - base);
    }
    str summary = name;
} [[format("summaryOf")]];

bitfield DelayImportAttributes {
    bool rva_based : 1;
    padding : 31;
};

struct BoundImportTable {
    u64 tableStart = addressof(this);
    BoundImportDescriptor descriptors[while(std::mem::read_unsigned($, 4) != 0)];
    str summary = std::format("{} modules", std::core::member_count(descriptors));
} [[format("summaryOf")]];

struct BoundImportDescriptor {
    u64 tableStart = parent.tableStart;
    u32 TimeDateStamp [[hex::inline_visualize("timestamp", this)]];
    u16 OffsetModuleName;
    u16 NumberOfModuleForwarderRefs;
    char name[] @ tableStart + OffsetModuleName;
    BoundForwarderRef forwarders[NumberOfModuleForwarderRefs];
    str summary = name;
} [[format("summaryOf")]];

struct BoundForwarderRef {
    u32 TimeDateStamp [[hex::inline_visualize("timestamp", this)]];
    u16 OffsetModuleName;
    u16 Reserved;
    char name[] @ parent.tableStart + OffsetModuleName;
    str summary = name;
} [[format("summaryOf")]];

struct ResourceTable {
    u64 imageStart = parent.imageStart;
    u64 resourceBase = addressof(this);
    ResourceDirectory<0, 0> root [[inline]];
    str summary = std::format("{} resource types", root.NumberOfNamedEntries + root.NumberOfIdEntries);
} [[format("summaryOf")]];

struct ResourceDirectory<auto Level, auto Type> {
    u64 imageStart = parent.imageStart;
    u64 resourceBase = parent.resourceBase;
    u32 Characteristics;
    u32 TimeDateStamp [[hex::inline_visualize("timestamp", this)]];
    u16 MajorVersion;
    u16 MinorVersion;
    u16 NumberOfNamedEntries;
    u16 NumberOfIdEntries;
    ResourceDirectoryEntry<Level, Type> entries[NumberOfNamedEntries + NumberOfIdEntries];
    str summary = std::format("{} entries", NumberOfNamedEntries + NumberOfIdEntries);
} [[format("summaryOf")]];

struct ResourceDirectoryEntry<auto Level, auto Type> {
    u64 imageStart = parent.imageStart;
    u64 resourceBase = parent.resourceBase;
    if (Level == 0) {
        ResourceTypeName Name;
    } else {
        ResourceEntryName Name;
    }
    ResourceEntryOffset OffsetToData;
    if (Name.is_string) {
        ResourceDirectoryString string @ resourceBase + Name.value;
    }
    if (OffsetToData.is_directory && Level == 0) {
        ResourceDirectory<1, Name.value> directory @ resourceBase + OffsetToData.value;
    } else if (OffsetToData.is_directory && Level == 1) {
        ResourceDirectory<2, Type> directory @ resourceBase + OffsetToData.value;
    } else if (OffsetToData.is_directory) {
        ResourceDirectory<3, Type> directory @ resourceBase + OffsetToData.value;
    } else {
        ResourceDataEntry<Type> data @ resourceBase + OffsetToData.value;
    }
    if (Name.is_string) {
        str summary = string.NameString;
    } else if (Level == 0) {
        str summary = enumName(std::format("{}", Name.value));
    } else if (Level == 2) {
        str summary = std::format("language {:#x}", Name.value);
    } else {
        str summary = std::format("{}", Name.value);
    }
} [[format("summaryOf")]];

bitfield ResourceTypeName {
    ResourceType value : 31;
    bool is_string : 1;
};

bitfield ResourceEntryName {
    u32 value : 31;
    bool is_string : 1;
};

bitfield ResourceEntryOffset {
    u32 value : 31;
    bool is_directory : 1;
};

enum ResourceType : u32 {
    Cursor = 1,
    Bitmap = 2,
    Icon = 3,
    Menu = 4,
    Dialog = 5,
    String = 6,
    FontDir = 7,
    Font = 8,
    Accelerator = 9,
    RcData = 10,
    MessageTable = 11,
    GroupCursor = 12,
    GroupIcon = 14,
    Version = 16,
    DlgInclude = 17,
    PlugPlay = 19,
    Vxd = 20,
    AniCursor = 21,
    AniIcon = 22,
    Html = 23,
    Manifest = 24,
};

struct ResourceDirectoryString {
    u16 Length;
    char16 NameString[Length];
};

struct ResourceDataEntry<auto Type> {
    u64 imageStart = parent.imageStart;
    u32 OffsetToData;
    u32 Size;
    u32 CodePage;
    u32 Reserved;
    u64 contents = dataOffsetOfRva(imageStart, OffsetToData);
    match (Type) {
        (ResourceType::Version): VersionBlock version @ contents;
        (ResourceType::Manifest): char manifest[Size] @ contents;
        (ResourceType::String): StringTableEntry strings[16] @ contents;
        (ResourceType::GroupIcon | ResourceType::GroupCursor): IconGroup group @ contents;
        (ResourceType::Icon): IconImage<Size> icon @ contents;
        (ResourceType::Cursor): CursorImage<Size> cursor @ contents;
        (ResourceType::Bitmap): BitmapImage<Size> bitmap @ contents;
        (_): u8 bytes[Size] @ contents [[sealed]];
    }
    str summary = std::format("{} bytes at {:#x}", Size, OffsetToData);
} [[format("summaryOf")]];

struct VersionBlock {
    u64 start = $;
    u16 wLength;
    u16 wValueLength;
    VersionValueType wType;
    char16 szKey[];
    padding[alignmentPadding($ - start, 4)];
    if (szKey == "VS_VERSION_INFO") {
        FixedFileInfo Value;
    } else if (szKey == "Translation") {
        Translation Value[wValueLength / 4];
    } else if (wType == VersionValueType::Text && wValueLength > 0) {
        char16 Value[wValueLength];
    } else if (wValueLength > 0) {
        u8 Value[wValueLength];
    }
    padding[alignmentPadding($ - start, 4)];
    VersionBlock Children[while($ < start + wLength)];
    if (wType == VersionValueType::Text && wValueLength > 0 && szKey != "VS_VERSION_INFO") {
        str summary = std::format("{} = {}", szKey, Value);
    } else {
        str summary = szKey;
    }
} [[format("summaryOf")]];

enum VersionValueType : u16 {
    Binary = 0,
    Text = 1,
};

struct Translation {
    u16 language;
    u16 charset;
    str summary = std::format("language {:#x} charset {}", language, charset);
} [[format("summaryOf")]];

struct FixedFileInfo {
    u32 dwSignature;
    u32 dwStrucVersion [[format("formatVersionPair")]];
    u32 dwFileVersionMS;
    u32 dwFileVersionLS;
    u32 dwProductVersionMS;
    u32 dwProductVersionLS;
    u32 dwFileFlagsMask;
    FileFlags dwFileFlags;
    FileOs dwFileOS;
    FileType dwFileType;
    u32 dwFileSubtype;
    u32 dwFileDateMS;
    u32 dwFileDateLS;
    str summary = std::format("file {} product {} {}", formatFullVersion(dwFileVersionMS, dwFileVersionLS),
        formatFullVersion(dwProductVersionMS, dwProductVersionLS), enumName(std::format("{}", dwFileType)));
} [[format("summaryOf")]];

fn formatVersionPair(u32 value) {
    return std::format("{}.{}", value >> 16, value & 0xffff);
};

fn formatFullVersion(u32 high, u32 low) {
    return std::format("{}.{}.{}.{}", high >> 16, high & 0xffff, low >> 16, low & 0xffff);
};

bitfield FileFlags {
    bool debug : 1;
    bool prerelease : 1;
    bool patched : 1;
    bool privatebuild : 1;
    bool infoinferred : 1;
    bool specialbuild : 1;
    padding : 26;
};

enum FileOs : u32 {
    Unknown = 0,
    Windows16 = 0x1,
    Pm16 = 0x2,
    Pm32 = 0x3,
    Windows32 = 0x4,
    Dos = 0x10000,
    DosWindows16 = 0x10001,
    DosWindows32 = 0x10004,
    Os216 = 0x20000,
    Os216Pm16 = 0x20002,
    Os232 = 0x30000,
    Os232Pm32 = 0x30003,
    Nt = 0x40000,
    NtWindows32 = 0x40004,
    WinCe = 0x50000,
};

enum FileType : u32 {
    Unknown = 0,
    Application = 1,
    Dll = 2,
    Driver = 3,
    Font = 4,
    Vxd = 5,
    StaticLibrary = 7,
};

struct StringTableEntry {
    u16 Length;
    char16 text[Length];
    str summary = text;
} [[format("summaryOf")]];

struct IconGroup {
    u16 idReserved;
    u16 idType;
    u16 idCount;
    IconGroupEntry entries[idCount];
    str summary = std::format("{} images", idCount);
} [[format("summaryOf")]];

struct IconGroupEntry {
    u8 bWidth;
    u8 bHeight;
    u8 bColorCount;
    u8 bReserved;
    u16 wPlanes;
    u16 wBitCount;
    u32 dwBytesInRes;
    u16 nID;
    str summary = std::format("{}x{} {} bpp, resource {}", bWidth, bHeight, wBitCount, nID);
} [[format("summaryOf")]];

struct IconImage<auto Size> {
    if (std::mem::read_unsigned($, 4, std::mem::Endian::Big) == 0x89504e47) {
        u8 png[Size] [[hex::visualize("image", this)]];
    } else {
        BitmapInfoHeader header;
        u8 bits[Size - sizeof(header)] [[sealed]];
    }
};

struct CursorImage<auto Size> {
    u16 xHotspot;
    u16 yHotspot;
    BitmapInfoHeader header;
    u8 bits[Size - 4 - sizeof(header)] [[sealed]];
};

struct BitmapImage<auto Size> {
    BitmapInfoHeader header;
    u8 bits[Size - sizeof(header)] [[sealed]];
};

struct BitmapInfoHeader {
    u32 biSize;
    s32 biWidth;
    s32 biHeight;
    u16 biPlanes;
    u16 biBitCount;
    BitmapCompression biCompression;
    u32 biSizeImage;
    s32 biXPelsPerMeter;
    s32 biYPelsPerMeter;
    u32 biClrUsed;
    u32 biClrImportant;
    str summary = std::format("{}x{} {} bpp", biWidth, biHeight, biBitCount);
} [[format("summaryOf")]];

enum BitmapCompression : u32 {
    Rgb = 0,
    Rle8 = 1,
    Rle4 = 2,
    Bitfields = 3,
    Jpeg = 4,
    Png = 5,
};

struct ExceptionTable {
    u64 imageStart = parent.imageStart;
    u32 size = parent.Size;
    match (parent.machine) {
        (Machine::Amd64): RuntimeFunction functions[size / 12];
        (Machine::Arm64 | Machine::Arm64Ec | Machine::Arm64X): Arm64RuntimeFunction functions[size / 8];
        (Machine::ArmNt | Machine::Thumb | Machine::Arm): ArmRuntimeFunction functions[size / 8];
        (_): u8 functions[size] [[sealed]];
    }
    str summary = std::format("{} bytes", size);
} [[format("summaryOf")]];

struct RuntimeFunction {
    u64 imageStart = parent.imageStart;
    u32 BeginAddress;
    u32 EndAddress;
    u32 UnwindInfoAddress;
    UnwindInfo unwind @ dataOffsetOfRva(imageStart, UnwindInfoAddress);
    str summary = std::format("{:#x}-{:#x}", BeginAddress, EndAddress);
} [[format("summaryOf")]];

struct UnwindInfo {
    u64 imageStart = parent.imageStart;
    UnwindVersionFlags VersionFlags;
    u8 SizeOfProlog;
    u8 CountOfCodes;
    UnwindFrame Frame;
    UnwindCode UnwindCode[CountOfCodes];
    padding[(CountOfCodes % 2) * 2];
    if (VersionFlags.chaininfo) {
        RuntimeFunction ChainedFunction;
    } else if (VersionFlags.ehandler || VersionFlags.uhandler) {
        u32 ExceptionHandler;
    }
    str summary = std::format("{} codes, prolog {} bytes", CountOfCodes, SizeOfProlog);
} [[format("summaryOf")]];

bitfield UnwindVersionFlags {
    u8 version : 3;
    bool ehandler : 1;
    bool uhandler : 1;
    bool chaininfo : 1;
    padding : 2;
};

bitfield UnwindFrame {
    u8 frame_register : 4;
    u8 frame_offset : 4;
};

struct UnwindCode {
    u8 CodeOffset;
    UnwindOperation Operation;
    str summary = std::format("+{:#x} {} {}", CodeOffset, enumName(std::format("{}", Operation.unwind_op)), Operation.op_info);
} [[format("summaryOf")]];

bitfield UnwindOperation {
    UnwindOp unwind_op : 4;
    u8 op_info : 4;
};

enum UnwindOp : u8 {
    PushNonvol = 0,
    AllocLarge = 1,
    AllocSmall = 2,
    SetFpreg = 3,
    SaveNonvol = 4,
    SaveNonvolFar = 5,
    Epilog = 6,
    SpareCode = 7,
    SaveXmm128 = 8,
    SaveXmm128Far = 9,
    PushMachframe = 10,
};

struct Arm64RuntimeFunction {
    u64 imageStart = parent.imageStart;
    u32 BeginAddress;
    u32 UnwindData;
    match (UnwindData & 3) {
        (0): Arm64UnwindData xdata @ dataOffsetOfRva(imageStart, UnwindData);
        (1): Arm64PackedUnwind packed @ addressof(UnwindData) [[no_unique_address]];
        (2): Arm64PackedUnwind fragment @ addressof(UnwindData) [[no_unique_address]];
        (_): padding[0];
    }
    str summary = std::format("{:#x} {}", BeginAddress, (UnwindData & 3) == 0 ? "xdata" : "packed");
} [[format("summaryOf")]];

bitfield Arm64PackedUnwind {
    u8 flag : 2;
    u16 function_length : 11;
    u8 reg_f : 3;
    u8 reg_i : 4;
    bool h : 1;
    u8 cr : 2;
    u16 frame_size : 9;
};

struct Arm64UnwindData {
    Arm64UnwindHeader header;
    if (header.epilog_count == 0 && header.code_words == 0) {
        Arm64UnwindExtension extension;
        u32 epilogCount = extension.epilog_count;
        u32 codeWords = extension.code_words;
    } else {
        u32 epilogCount = header.epilog_count;
        u32 codeWords = header.code_words;
    }
    if (!header.e) {
        Arm64EpilogScope epilogs[epilogCount];
    }
    u32 codes[codeWords];
    if (header.x) {
        u32 ExceptionHandler;
    }
    str summary = std::format("function {} bytes, {} code words", header.function_length * 4, codeWords);
} [[format("summaryOf")]];

bitfield Arm64UnwindHeader {
    u32 function_length : 18;
    u8 version : 2;
    bool x : 1;
    bool e : 1;
    u8 epilog_count : 5;
    u8 code_words : 5;
};

bitfield Arm64UnwindExtension {
    u16 epilog_count : 16;
    u8 code_words : 8;
    padding : 8;
};

bitfield Arm64EpilogScope {
    u32 epilog_start_offset : 18;
    padding : 4;
    u16 epilog_start_index : 10;
};

struct ArmRuntimeFunction {
    u64 imageStart = parent.imageStart;
    u32 BeginAddress;
    u32 UnwindData;
    match (UnwindData & 3) {
        (0): ArmUnwindData xdata @ dataOffsetOfRva(imageStart, UnwindData);
        (1 | 2): ArmPackedUnwind packed @ addressof(UnwindData) [[no_unique_address]];
        (_): padding[0];
    }
    str summary = std::format("{:#x} {}", BeginAddress, (UnwindData & 3) == 0 ? "xdata" : "packed");
} [[format("summaryOf")]];

bitfield ArmPackedUnwind {
    u8 flag : 2;
    u16 function_length : 11;
    u8 ret : 2;
    bool h : 1;
    u8 reg : 3;
    bool r : 1;
    bool l : 1;
    bool c : 1;
    u16 stack_adjust : 10;
};

struct ArmUnwindData {
    ArmUnwindHeader header;
    if (header.epilog_count == 0 && header.code_words == 0) {
        Arm64UnwindExtension extension;
        u32 epilogCount = extension.epilog_count;
        u32 codeWords = extension.code_words;
    } else {
        u32 epilogCount = header.epilog_count;
        u32 codeWords = header.code_words;
    }
    if (!header.e) {
        ArmEpilogScope epilogs[epilogCount];
    }
    u32 codes[codeWords];
    if (header.x) {
        u32 ExceptionHandler;
    }
    str summary = std::format("function {} bytes, {} code words", header.function_length * 2, codeWords);
} [[format("summaryOf")]];

bitfield ArmUnwindHeader {
    u32 function_length : 18;
    u8 version : 2;
    bool x : 1;
    bool e : 1;
    bool f : 1;
    u8 epilog_count : 5;
    u8 code_words : 4;
};

bitfield ArmEpilogScope {
    u32 epilog_start_offset : 18;
    u8 res : 2;
    u8 condition : 4;
    u8 epilog_start_index : 8;
};

struct BaseRelocationTable {
    u64 end = addressof(this) + parent.Size;
    match (parent.machine) {
        (Machine::Arm | Machine::Thumb | Machine::ArmNt): BaseRelocationBlock<ArmBaseRelocationType> blocks[while($ < end)];
        (Machine::R3000 | Machine::R4000 | Machine::R10000 | Machine::WceMipsV2 | Machine::Mips16 | Machine::MipsFpu | Machine::MipsFpu16):
            BaseRelocationBlock<MipsBaseRelocationType> blocks[while($ < end)];
        (Machine::RiscV32 | Machine::RiscV64 | Machine::RiscV128): BaseRelocationBlock<RiscVBaseRelocationType> blocks[while($ < end)];
        (Machine::LoongArch32 | Machine::LoongArch64): BaseRelocationBlock<LoongArchBaseRelocationType> blocks[while($ < end)];
        (Machine::Ia64): BaseRelocationBlock<Ia64BaseRelocationType> blocks[while($ < end)];
        (_): BaseRelocationBlock<BaseRelocationType> blocks[while($ < end)];
    }
    str summary = std::format("{} bytes", parent.Size);
} [[format("summaryOf")]];

struct BaseRelocationBlock<Type> {
    u32 VirtualAddress;
    u32 SizeOfBlock;
    BaseRelocationEntry<Type> entries[(SizeOfBlock - 8) / 2];
    str summary = std::format("page {:#x}, {} entries", VirtualAddress, (SizeOfBlock - 8) / 2);
} [[format("summaryOf")]];

bitfield BaseRelocationEntry<Type> {
    u16 offset : 12;
    Type type : 4;
} [[format("describeBaseRelocation")]];

fn describeBaseRelocation(ref auto entry) {
    return std::format("{} +{:#x}", enumName(std::format("{}", entry.type)), entry.offset);
};

enum BaseRelocationType : u8 {
    Absolute = 0,
    High = 1,
    Low = 2,
    HighLow = 3,
    HighAdj = 4,
    Dir64 = 10,
};

enum ArmBaseRelocationType : u8 {
    Absolute = 0,
    High = 1,
    Low = 2,
    HighLow = 3,
    HighAdj = 4,
    Mov32 = 5,
    ThumbMov32 = 7,
    Dir64 = 10,
};

enum MipsBaseRelocationType : u8 {
    Absolute = 0,
    High = 1,
    Low = 2,
    HighLow = 3,
    HighAdj = 4,
    JmpAddr = 5,
    JmpAddr16 = 9,
    Dir64 = 10,
};

enum RiscVBaseRelocationType : u8 {
    Absolute = 0,
    High = 1,
    Low = 2,
    HighLow = 3,
    HighAdj = 4,
    High20 = 5,
    Low12I = 7,
    Low12S = 8,
    Dir64 = 10,
};

enum LoongArchBaseRelocationType : u8 {
    Absolute = 0,
    High = 1,
    Low = 2,
    HighLow = 3,
    HighAdj = 4,
    MarkLa = 8,
    Dir64 = 10,
};

enum Ia64BaseRelocationType : u8 {
    Absolute = 0,
    High = 1,
    Low = 2,
    HighLow = 3,
    HighAdj = 4,
    Imm64 = 9,
    Dir64 = 10,
};

struct DebugTable {
    u64 imageStart = parent.imageStart;
    DebugDirectory entries[parent.Size / 28];
    str summary = std::format("{} entries", parent.Size / 28);
} [[format("summaryOf")]];

struct DebugDirectory {
    u64 imageStart = parent.imageStart;
    u32 Characteristics;
    u32 TimeDateStamp [[hex::inline_visualize("timestamp", this)]];
    u16 MajorVersion;
    u16 MinorVersion;
    DebugType Type;
    u32 SizeOfData;
    u32 AddressOfRawData;
    u32 PointerToRawData;
    if (SizeOfData > 0) {
        u64 data = debugDataOffset(imageStart, AddressOfRawData, PointerToRawData);
        match (Type) {
            (DebugType::CodeView): CodeViewInfo codeview @ data;
            (DebugType::Pogo): PogoInfo pogo @ data;
            (DebugType::VcFeature): VcFeatureInfo features @ data;
            (DebugType::Repro): ReproInfo repro @ data;
            (DebugType::ExDllCharacteristics): ExtendedDllCharacteristics characteristics @ data;
            (DebugType::Fpo): FpoData fpo[SizeOfData / 16] @ data;
            (DebugType::Misc): DebugMisc misc @ data;
            (_): u8 bytes[SizeOfData] @ data [[sealed]];
        }
    }
    str summary = std::format("{} ({} bytes)", enumName(std::format("{}", Type)), SizeOfData);
} [[format("summaryOf")]];

enum DebugType : u32 {
    Unknown = 0,
    Coff = 1,
    CodeView = 2,
    Fpo = 3,
    Misc = 4,
    Exception = 5,
    Fixup = 6,
    OmapToSrc = 7,
    OmapFromSrc = 8,
    Borland = 9,
    Reserved10 = 10,
    Clsid = 11,
    VcFeature = 12,
    Pogo = 13,
    Iltcg = 14,
    Mpx = 15,
    Repro = 16,
    Spgo = 18,
    ExDllCharacteristics = 20,
    PerfMap = 21,
};

struct CodeViewInfo {
    match (std::mem::read_unsigned($, 4)) {
        (CodeViewSignature::Pdb70): Pdb70Info pdb70 [[inline]];
        (CodeViewSignature::Pdb20): Pdb20Info pdb20 [[inline]];
        (_): u8 bytes[parent.SizeOfData] [[sealed]];
    }
};

enum CodeViewSignature : u32 {
    Pdb20 = 0x3031424e,
    Pdb70 = 0x53445352,
};

struct Pdb70Info {
    CodeViewSignature CvSignature;
    Guid Signature;
    u32 Age;
    char PdbFileName[];
    str summary = std::format("{} age {} {}", std::core::formatted_value(Signature), Age, PdbFileName);
} [[format("summaryOf")]];

struct Pdb20Info {
    CodeViewSignature CvSignature;
    u32 Offset;
    u32 Signature [[hex::inline_visualize("timestamp", this)]];
    u32 Age;
    char PdbFileName[];
    str summary = std::format("age {} {}", Age, PdbFileName);
} [[format("summaryOf")]];

struct Guid {
    u32 Data1;
    u16 Data2;
    u16 Data3;
    u8 Data4[8];
    str summary = std::format("{{{:08X}-{:04X}-{:04X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}}}", Data1, Data2, Data3, Data4[0],
        Data4[1], Data4[2], Data4[3], Data4[4], Data4[5], Data4[6], Data4[7]);
} [[format("summaryOf")]];

struct PogoInfo {
    PogoSignature Signature;
    PogoEntry entries[while($ < addressof(this) + parent.SizeOfData)];
    str summary = std::format("{} {} sections", enumName(std::format("{}", Signature)), std::core::member_count(entries));
} [[format("summaryOf")]];

enum PogoSignature : u32 {
    Ltcg = 0x4c544347,
    Pgi = 0x50474900,
    Pgo = 0x50474f00,
    Pgu = 0x50475500,
};

struct PogoEntry {
    u32 Rva;
    u32 Size;
    char Name[];
    padding[alignmentPadding($ - addressof(this), 4)];
    str summary = std::format("{} {:#x} ({} bytes)", Name, Rva, Size);
} [[format("summaryOf")]];

struct VcFeatureInfo {
    u32 PreVC11;
    u32 CCpp;
    u32 Gs;
    u32 Sdl;
    u32 GuardN;
    str summary = std::format("C/C++ {} GS {} SDL {} CFG {}", CCpp, Gs, Sdl, GuardN);
} [[format("summaryOf")]];

struct ReproInfo {
    u32 Size;
    u8 Hash[Size] [[format("formatHex")]];
    str summary = formatHex(Hash);
} [[format("summaryOf")]];

bitfield ExtendedDllCharacteristics {
    bool cet_compat : 1;
    bool cet_compat_strict_mode : 1;
    bool cet_set_context_ip_validation_relaxed_mode : 1;
    bool cet_dynamic_apis_allow_in_proc_only : 1;
    bool cet_reserved_1 : 1;
    bool cet_reserved_2 : 1;
    bool forward_cfi_compat : 1;
    bool hotpatch_compatible : 1;
    padding : 24;
};

struct FpoData {
    u32 ulOffStart;
    u32 cbProcSize;
    u32 cdwLocals;
    u16 cdwParams;
    FpoAttributes attributes;
    str summary = std::format("{:#x} {} bytes", ulOffStart, cbProcSize);
} [[format("summaryOf")]];

bitfield FpoAttributes {
    u8 cbProlog : 8;
    u8 cbRegs : 3;
    bool fHasSEH : 1;
    bool fUseBP : 1;
    padding : 1;
    FrameType cbFrame : 2;
};

enum FrameType : u8 {
    Fpo = 0,
    Trap = 1,
    Tss = 2,
    NonFpo = 3,
};

struct DebugMisc {
    u32 DataType;
    u32 Length;
    bool Unicode;
    u8 Reserved[3];
    if (Unicode) {
        char16 Data[(Length - 12) / 2];
    } else {
        char Data[Length - 12];
    }
    str summary = Data;
} [[format("summaryOf")]];

struct TlsDirectory<Addr> {
    u64 imageStart = parent.imageStart;
    u64 imageBase = parent.imageBase;
    Addr StartAddressOfRawData;
    Addr EndAddressOfRawData;
    Addr AddressOfIndex;
    Addr AddressOfCallBacks;
    u32 SizeOfZeroFill;
    TlsCharacteristics Characteristics;
    if (AddressOfCallBacks != 0) {
        Addr callbacks[while(std::mem::read_unsigned($, sizeof(Addr)) != 0)] @ dataOffsetOfRva(imageStart, AddressOfCallBacks - imageBase);
    }
    str summary = std::format("{} bytes of template, {} zero fill", EndAddressOfRawData - StartAddressOfRawData, SizeOfZeroFill);
} [[format("summaryOf")]];

bitfield TlsCharacteristics {
    padding : 20;
    u8 alignment : 4 [[format("formatSectionAlignment")]];
    padding : 8;
};

struct LoadConfigDirectory<Addr> {
    u64 imageStart = parent.imageStart;
    u64 imageBase = parent.imageBase;
    u64 start = $;
    u32 Size;
    u32 TimeDateStamp [[hex::inline_visualize("timestamp", this)]];
    u16 MajorVersion;
    u16 MinorVersion;
    u32 GlobalFlagsClear;
    u32 GlobalFlagsSet;
    u32 CriticalSectionDefaultTimeout;
    Addr DeCommitFreeBlockThreshold;
    Addr DeCommitTotalFreeThreshold;
    Addr LockPrefixTable;
    Addr MaximumAllocationSize;
    Addr VirtualMemoryThreshold;
    if (sizeof(Addr) == 8) {
        Addr ProcessAffinityMask;
        u32 ProcessHeapFlags;
    } else {
        u32 ProcessHeapFlags;
        Addr ProcessAffinityMask;
    }
    u16 CSDVersion;
    DependentLoadFlags DependentLoadFlags;
    Addr EditList;
    Addr SecurityCookie;
    Addr SEHandlerTable;
    Addr SEHandlerCount;
    if ($ - start < Size) {
        Addr GuardCFCheckFunctionPointer;
        Addr GuardCFDispatchFunctionPointer;
        Addr GuardCFFunctionTable;
        Addr GuardCFFunctionCount;
        GuardFlags GuardFlags;
        if (GuardCFFunctionTable != 0 && GuardCFFunctionCount != 0) {
            u32 extraBytes = GuardFlags.function_table_size;
            GuardFunction guardFunctions[GuardCFFunctionCount] @ dataOffsetOfRva(imageStart, GuardCFFunctionTable - imageBase);
        }
    }
    if ($ - start < Size) {
        LoadConfigCodeIntegrity CodeIntegrity;
    }
    if ($ - start < Size) {
        Addr GuardAddressTakenIatEntryTable;
        Addr GuardAddressTakenIatEntryCount;
        Addr GuardLongJumpTargetTable;
        Addr GuardLongJumpTargetCount;
    }
    if ($ - start < Size) {
        Addr DynamicValueRelocTable;
        Addr CHPEMetadataPointer;
        Addr GuardRFFailureRoutine;
        Addr GuardRFFailureRoutineFunctionPointer;
        u32 DynamicValueRelocTableOffset;
        u16 DynamicValueRelocTableSection;
        u16 Reserved2;
        Addr GuardRFVerifyStackPointerFunctionPointer;
    }
    if ($ - start < Size) {
        u32 HotPatchTableOffset;
        u32 Reserved3;
    }
    if ($ - start < Size) {
        Addr EnclaveConfigurationPointer;
    }
    if ($ - start < Size) {
        Addr VolatileMetadataPointer;
    }
    if ($ - start < Size) {
        Addr GuardEHContinuationTable;
        Addr GuardEHContinuationCount;
    }
    if ($ - start < Size) {
        Addr GuardXFGCheckFunctionPointer;
        Addr GuardXFGDispatchFunctionPointer;
        Addr GuardXFGTableDispatchFunctionPointer;
    }
    if ($ - start < Size) {
        Addr CastGuardOsDeterminedFailureMode;
    }
    if ($ - start < Size) {
        Addr GuardMemcpyFunctionPointer;
    }
    str summary = std::format("{} bytes, security cookie {:#x}", Size, SecurityCookie);
} [[format("summaryOf")]];

bitfield DependentLoadFlags {
    padding : 8;
    bool search_dll_load_dir : 1;
    bool search_application_dir : 1;
    bool search_user_dirs : 1;
    bool search_system32 : 1;
    bool search_default_dirs : 1;
    padding : 3;
};

bitfield GuardFlags {
    padding : 8;
    bool cf_instrumented : 1;
    bool cfw_instrumented : 1;
    bool cf_function_table_present : 1;
    bool security_cookie_unused : 1;
    bool protect_delayload_iat : 1;
    bool delayload_iat_in_its_own_section : 1;
    bool cf_export_suppression_info_present : 1;
    bool cf_enable_export_suppression : 1;
    bool cf_longjump_table_present : 1;
    bool rf_instrumented : 1;
    bool rf_enable : 1;
    bool rf_strict : 1;
    bool retpoline_present : 1;
    padding : 1;
    bool eh_continuation_table_present : 1;
    bool xfg_enabled : 1;
    bool castguard_present : 1;
    bool memcpy_present : 1;
    padding : 2;
    u8 function_table_size : 4;
};

struct GuardFunction {
    u32 rva;
    if (parent.extraBytes > 0) {
        GuardFunctionFlags flags;
        padding[parent.extraBytes - 1];
    }
    str summary = std::format("{:#x}", rva);
} [[format("summaryOf")]];

bitfield GuardFunctionFlags {
    bool export_suppressed : 1;
    padding : 7;
};

struct LoadConfigCodeIntegrity {
    u16 Flags;
    u16 Catalog;
    u32 CatalogOffset;
    u32 Reserved;
};

struct ClrHeader {
    u64 imageStart = parent.imageStart;
    u32 cb;
    u16 MajorRuntimeVersion;
    u16 MinorRuntimeVersion;
    ClrDataDirectory MetaData;
    ClrFlags Flags;
    if (Flags.native_entrypoint) {
        u32 EntryPointRVA;
    } else {
        u32 EntryPointToken;
    }
    ClrDataDirectory Resources;
    ClrDataDirectory StrongNameSignature;
    ClrDataDirectory CodeManagerTable;
    ClrDataDirectory VTableFixups;
    ClrDataDirectory ExportAddressTableJumps;
    ClrDataDirectory ManagedNativeHeader;
    if (MetaData.VirtualAddress != 0) {
        MetadataRoot metadata @ dataOffsetOfRva(imageStart, MetaData.VirtualAddress);
    }
    str summary = std::format("runtime {}.{}", MajorRuntimeVersion, MinorRuntimeVersion);
} [[format("summaryOf")]];

struct ClrDataDirectory {
    u32 VirtualAddress;
    u32 Size;
    str summary = std::format("{:#x} ({} bytes)", VirtualAddress, Size);
} [[format("summaryOf")]];

bitfield ClrFlags {
    bool il_only : 1;
    bool requires_32bit : 1;
    bool il_library : 1;
    bool strong_name_signed : 1;
    bool native_entrypoint : 1;
    padding : 11;
    bool track_debug_data : 1;
    bool prefers_32bit : 1;
    padding : 14;
};

struct MetadataRoot {
    u32 Signature;
    u16 MajorVersion;
    u16 MinorVersion;
    u32 Reserved;
    u32 Length;
    char Version[Length];
    u16 Flags;
    u16 Streams;
    MetadataStreamHeader streams[Streams];
    str summary = std::format("{} with {} streams", Version, Streams);
} [[format("summaryOf")]];

struct MetadataStreamHeader {
    u32 Offset;
    u32 Size;
    char Name[];
    padding[alignmentPadding($ - addressof(this), 4)];
    str summary = std::format("{} ({} bytes)", Name, Size);
} [[format("summaryOf")]];

struct SectionHeader {
    u64 imageStart = parent.imageStart;
    Machine machine = parent.FileHeader.Machine;
    char Name[8];
    u32 VirtualSize;
    u32 VirtualAddress;
    u32 SizeOfRawData;
    u32 PointerToRawData;
    u32 PointerToRelocations;
    u32 PointerToLinenumbers;
    u16 NumberOfRelocations;
    u16 NumberOfLinenumbers;
    SectionCharacteristics Characteristics;
    u64 contentsSize = sectionContentsSize(VirtualSize, SizeOfRawData);
    if (contentsSize > 0) {
        u8 contents[contentsSize] @ sectionContentsOffset(imageStart, VirtualAddress, PointerToRawData) [[sealed]];
    }
    if (NumberOfRelocations > 0 && fileOffsetIsMapped()) {
        CoffRelocation relocations[NumberOfRelocations] @ imageStart + PointerToRelocations;
    }
    str summary = std::format("{} {:#x}-{:#x} {}", fixedString(addressof(Name), 8), VirtualAddress, VirtualAddress + VirtualSize,
        protectionString(Characteristics));
} [[format("summaryOf")]];

fn protectionString(ref auto characteristics) {
    return (characteristics.mem_read ? "r" : "-") + (characteristics.mem_write ? "w" : "-") + (characteristics.mem_execute ? "x" : "-");
};

bitfield SectionCharacteristics {
    padding : 1;
    bool type_no_load : 1;
    padding : 1;
    bool type_no_pad : 1;
    padding : 1;
    bool cnt_code : 1;
    bool cnt_initialized_data : 1;
    bool cnt_uninitialized_data : 1;
    bool lnk_other : 1;
    bool lnk_info : 1;
    padding : 1;
    bool lnk_remove : 1;
    bool lnk_comdat : 1;
    padding : 1;
    bool no_defer_spec_exc : 1;
    bool gprel : 1;
    padding : 1;
    bool mem_purgeable : 1;
    bool mem_locked : 1;
    bool mem_preload : 1;
    u8 alignment : 4 [[format("formatSectionAlignment")]];
    bool lnk_nreloc_ovfl : 1;
    bool mem_discardable : 1;
    bool mem_not_cached : 1;
    bool mem_not_paged : 1;
    bool mem_shared : 1;
    bool mem_execute : 1;
    bool mem_read : 1;
    bool mem_write : 1;
};

fn formatSectionAlignment(u8 encoded) {
    if (encoded == 0) {
        return "default";
    }
    return std::format("{} bytes", 1 << (encoded - 1));
};

struct CoffRelocation {
    u64 imageStart = parent.imageStart;
    u32 VirtualAddress;
    u32 SymbolTableIndex;
    match (parent.machine) {
        (Machine::I386): I386RelocationType Type;
        (Machine::Amd64): Amd64RelocationType Type;
        (Machine::Arm | Machine::Thumb | Machine::ArmNt): ArmRelocationType Type;
        (Machine::Arm64 | Machine::Arm64Ec | Machine::Arm64X): Arm64RelocationType Type;
        (_): u16 Type;
    }
    str summary = std::format("{:#x} {}", VirtualAddress, coffSymbolName(imageStart, SymbolTableIndex));
} [[format("summaryOf")]];

enum I386RelocationType : u16 {
    Absolute = 0x0,
    Dir16 = 0x1,
    Rel16 = 0x2,
    Dir32 = 0x6,
    Dir32Nb = 0x7,
    Seg12 = 0x9,
    Section = 0xa,
    Secrel = 0xb,
    Token = 0xc,
    Secrel7 = 0xd,
    Rel32 = 0x14,
};

enum Amd64RelocationType : u16 {
    Absolute = 0x0,
    Addr64 = 0x1,
    Addr32 = 0x2,
    Addr32Nb = 0x3,
    Rel32 = 0x4,
    Rel32_1 = 0x5,
    Rel32_2 = 0x6,
    Rel32_3 = 0x7,
    Rel32_4 = 0x8,
    Rel32_5 = 0x9,
    Section = 0xa,
    Secrel = 0xb,
    Secrel7 = 0xc,
    Token = 0xd,
    Srel32 = 0xe,
    Pair = 0xf,
    Sspan32 = 0x10,
};

enum ArmRelocationType : u16 {
    Absolute = 0x0,
    Addr32 = 0x1,
    Addr32Nb = 0x2,
    Branch24 = 0x3,
    Branch11 = 0x4,
    Token = 0x5,
    Blx24 = 0x8,
    Blx11 = 0x9,
    Rel32 = 0xa,
    Section = 0xe,
    Secrel = 0xf,
    Mov32A = 0x10,
    Mov32T = 0x11,
    Branch20T = 0x12,
    Branch24T = 0x14,
    Blx23T = 0x15,
    Pair = 0x16,
};

enum Arm64RelocationType : u16 {
    Absolute = 0x0,
    Addr32 = 0x1,
    Addr32Nb = 0x2,
    Branch26 = 0x3,
    PageBaseRel21 = 0x4,
    Rel21 = 0x5,
    PageOffset12A = 0x6,
    PageOffset12L = 0x7,
    Secrel = 0x8,
    SecrelLow12A = 0x9,
    SecrelHigh12A = 0xa,
    SecrelLow12L = 0xb,
    Token = 0xc,
    Section = 0xd,
    Addr64 = 0xe,
    Branch19 = 0xf,
    Branch14 = 0x10,
    Rel32 = 0x11,
};

struct CoffSymbolTable {
    u64 imageStart = parent.imageStart;
    u32 count = parent.NumberOfSymbols;
    u64 stringTable = addressof(this) + count * 18;
    CoffSymbol symbols[while($ < stringTable)];
    u32 stringTableSize @ stringTable;
    CString strings[while($ < stringTable + stringTableSize)] @ stringTable + 4;
    str summary = std::format("{} symbols", count);
} [[format("summaryOf")]];

struct CoffSymbol {
    u64 stringTable = parent.stringTable;
    if (std::mem::read_unsigned($, 4) == 0) {
        u32 Zeroes;
        u32 Offset;
        char LongName[] @ stringTable + 4 + Offset;
        str name = LongName;
    } else {
        char ShortName[8];
        str name = fixedString(addressof(ShortName), 8);
    }
    u32 Value;
    CoffSectionNumber SectionNumber;
    CoffSymbolType Type;
    StorageClass StorageClass;
    u8 NumberOfAuxSymbols;
    AuxSymbol aux[NumberOfAuxSymbols];
    str summary = std::format("{} {} {:#x}", name, enumName(std::format("{}", StorageClass)), Value);
} [[format("summaryOf")]];

enum CoffSectionNumber : s16 {
    Undefined = 0,
    Absolute = -1,
    Debug = -2,
    Section = 1 ... 0x7fff,
};

bitfield CoffSymbolType {
    SymbolBaseType base : 4;
    SymbolComplexType complex : 4;
    padding : 8;
};

enum SymbolBaseType : u8 {
    Null = 0,
    Void = 1,
    Char = 2,
    Short = 3,
    Int = 4,
    Long = 5,
    Float = 6,
    Double = 7,
    Struct = 8,
    Union = 9,
    Enum = 10,
    MemberOfEnum = 11,
    Byte = 12,
    Word = 13,
    Uint = 14,
    Dword = 15,
};

enum SymbolComplexType : u8 {
    Null = 0,
    Pointer = 1,
    Function = 2,
    Array = 3,
};

enum StorageClass : u8 {
    Null = 0,
    Automatic = 1,
    External = 2,
    Static = 3,
    Register = 4,
    ExternalDef = 5,
    Label = 6,
    UndefinedLabel = 7,
    MemberOfStruct = 8,
    Argument = 9,
    StructTag = 10,
    MemberOfUnion = 11,
    UnionTag = 12,
    TypeDefinition = 13,
    UndefinedStatic = 14,
    EnumTag = 15,
    MemberOfEnum = 16,
    RegisterParam = 17,
    BitField = 18,
    Block = 100,
    Function = 101,
    EndOfStruct = 102,
    File = 103,
    Section = 104,
    WeakExternal = 105,
    ClrToken = 107,
    EndOfFunction = 255,
};

struct AuxSymbol {
    if (parent.StorageClass == StorageClass::File) {
        char FileName[18];
    } else if (parent.StorageClass == StorageClass::Static && parent.SectionNumber > 0) {
        AuxSectionDefinition section;
    } else if (parent.StorageClass == StorageClass::WeakExternal) {
        AuxWeakExternal weak;
    } else if (parent.StorageClass == StorageClass::ClrToken) {
        AuxClrToken token;
    } else if (parent.StorageClass == StorageClass::Function) {
        AuxBeginEndFunction marker;
    } else if (parent.Type.complex == SymbolComplexType::Function) {
        AuxFunctionDefinition function;
    } else {
        u8 bytes[18] [[sealed]];
    }
};

struct AuxFunctionDefinition {
    u32 TagIndex;
    u32 TotalSize;
    u32 PointerToLinenumber;
    u32 PointerToNextFunction;
    u16 Unused;
};

struct AuxBeginEndFunction {
    u32 Unused1;
    u16 Linenumber;
    u8 Unused2[6];
    u32 PointerToNextFunction;
    u16 Unused3;
};

struct AuxWeakExternal {
    u32 TagIndex;
    WeakExternalCharacteristics Characteristics;
    u8 Unused[10];
};

enum WeakExternalCharacteristics : u32 {
    SearchNoLibrary = 1,
    SearchLibrary = 2,
    SearchAlias = 3,
    AntiDependency = 4,
};

struct AuxSectionDefinition {
    u32 Length;
    u16 NumberOfRelocations;
    u16 NumberOfLinenumbers;
    u32 CheckSum;
    u16 Number;
    ComdatSelection Selection;
    u8 Unused[3];
};

enum ComdatSelection : u8 {
    None = 0,
    NoDuplicates = 1,
    Any = 2,
    SameSize = 3,
    ExactMatch = 4,
    Associative = 5,
    Largest = 6,
    Newest = 7,
};

struct AuxClrToken {
    u8 AuxType;
    u8 Reserved1;
    u32 SymbolTableIndex;
    u8 Reserved2[12];
};

struct CString {
    char text[];
    str summary = text;
} [[format("summaryOf")]];

fn coffSymbolName(u64 imageStart, u32 index) {
    u64 table = imageStart + std::mem::read_unsigned(coffFileHeader(imageStart) + 8, 4);
    u64 symbol = table + index * 18;
    if (std::mem::read_unsigned(symbol, 4) == 0) {
        u64 strings = table + std::mem::read_unsigned(coffFileHeader(imageStart) + 12, 4) * 18;
        u64 name = strings + std::mem::read_unsigned(symbol + 4, 4);
        return std::mem::read_string(name, cstringLength(name, 1024));
    }
    return fixedString(symbol, 8);
};

fn coffFileHeader(u64 imageStart) {
    if (std::mem::read_unsigned(imageStart, 2) == 0x5a4d) {
        return imageStart + std::mem::read_unsigned(imageStart + 0x3c, 4) + 4;
    }
    return imageStart;
};

fn disassemblerArchitecture(Machine machine) {
    match (machine) {
        (Machine::I386 | Machine::ChpeX86): return "x86";
        (Machine::Amd64): return "x86_64";
        (Machine::Arm): return "arm";
        (Machine::Thumb | Machine::ArmNt): return "thumb";
        (Machine::Arm64 | Machine::Arm64Ec | Machine::Arm64X): return "arm64";
        (Machine::PowerPc | Machine::PowerPcFp): return "ppc";
        (Machine::R3000 | Machine::R4000 | Machine::R10000 | Machine::WceMipsV2 | Machine::Mips16 | Machine::MipsFpu | Machine::MipsFpu16):
            return "mips";
        (_): return "";
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

#ifdef __MEMORY__
fn dataOffsetOfRva(u64 imageStart, u64 rva) {
    return imageStart + rva;
};

fn sectionContentsOffset(u64 imageStart, u32 virtualAddress, u32 pointerToRawData) {
    return imageStart + virtualAddress;
};

fn sectionContentsSize(u32 virtualSize, u32 sizeOfRawData) {
    return virtualSize;
};

fn debugDataOffset(u64 imageStart, u32 rva, u32 fileOffset) {
    return imageStart + rva;
};

fn fileOffsetIsMapped() {
    return false;
};
#else
fn dataOffsetOfRva(u64 imageStart, u64 rva) {
    SectionMapping section = sectionContainingRva(imageStart, rva);
    if (section.rawSize == 0) {
        return imageStart + rva;
    }
    return imageStart + section.rawPointer + (rva - section.virtualAddress);
};

fn sectionContentsOffset(u64 imageStart, u32 virtualAddress, u32 pointerToRawData) {
    return imageStart + pointerToRawData;
};

fn sectionContentsSize(u32 virtualSize, u32 sizeOfRawData) {
    return sizeOfRawData;
};

fn debugDataOffset(u64 imageStart, u32 rva, u32 fileOffset) {
    return imageStart + fileOffset;
};

fn fileOffsetIsMapped() {
    return true;
};
#endif

struct SectionMapping {
    u32 virtualAddress;
    u32 rawPointer;
    u32 rawSize;
};

fn sectionContainingRva(u64 imageStart, u64 rva) {
    SectionMapping found;
    u64 fileHeader = coffFileHeader(imageStart);
    u32 count = std::mem::read_unsigned(fileHeader + 2, 2);
    u64 header = fileHeader + 20 + std::mem::read_unsigned(fileHeader + 16, 2);
    for (u32 i = 0, i < count, i = i + 1) {
        u32 virtualSize = std::mem::read_unsigned(header + 8, 4);
        u32 virtualAddress = std::mem::read_unsigned(header + 12, 4);
        u32 rawSize = std::mem::read_unsigned(header + 16, 4);
        if (rva >= virtualAddress && rva < virtualAddress + std::math::max(virtualSize, rawSize)) {
            found.virtualAddress = virtualAddress;
            found.rawPointer = std::mem::read_unsigned(header + 20, 4);
            found.rawSize = rawSize;
            return found;
        }
        header = header + 40;
    }
    return found;
};
