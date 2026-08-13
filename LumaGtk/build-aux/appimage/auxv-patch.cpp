#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <elf.h>
#include <link.h>
#include <optional>
#include <span>
#include <string_view>

extern "C" char **environ;

namespace {

using Auxv = ElfW(auxv_t);
using Phdr = ElfW(Phdr);

inline constexpr std::size_t kAuxvMax = 128;

class File {
public:
  File(const char *path, const char *mode) noexcept
      : f_(std::fopen(path, mode)) {}
  ~File() {
    if (f_)
      std::fclose(f_);
  }
  File(const File &) = delete;
  File &operator=(const File &) = delete;
  explicit operator bool() const noexcept { return f_ != nullptr; }
  [[nodiscard]] FILE *get() const noexcept { return f_; }

private:
  FILE *f_;
};

struct Objects {
  const Phdr *exe_phdr = nullptr;
  ElfW(Half) exe_phnum = 0;
  std::optional<std::uintptr_t> interp_base;
};

struct StackRegion {
  std::uintptr_t start = 0, end = 0;
};

struct MapsInfo {
  StackRegion stack;
  std::optional<std::uintptr_t> interp_base;
};

// Locate auxv on the kernel's original stack by scanning backward from stack.end.
// Frida's gummoduleregistry reads the original stack via [stack] in /proc/self/maps.
[[nodiscard]] std::span<Auxv> find_orig_auxv(StackRegion s) noexcept {
  if (s.end - s.start < sizeof(Auxv))
    return {};

  Auxv needle{};
  needle.a_type = AT_PHENT;
  needle.a_un.a_val = sizeof(Phdr);

  std::uintptr_t addr = (s.end - sizeof(needle)) & ~std::uintptr_t{7};
  Auxv *last_match = nullptr;

  for (; addr >= s.start; addr -= sizeof(void *)) {
    if (std::memcmp(reinterpret_cast<void *>(addr), &needle, sizeof(needle)) == 0) {
      last_match = reinterpret_cast<Auxv *>(addr);
      break;
    }
  }

  if (!last_match)
    return {};

  constexpr std::size_t kPageSize = 4096;
  Auxv *auxv_start = nullptr;
  for (Auxv *cur = last_match - 1; reinterpret_cast<std::uintptr_t>(cur) >= s.start; --cur) {
    if (cur->a_type >= kPageSize) {
      auxv_start = cur + 1;
      break;
    }
  }

  if (!auxv_start)
    return {};

  Auxv *auxv_end = nullptr;
  for (Auxv *cur = last_match + 1; reinterpret_cast<std::uintptr_t>(cur + 1) <= s.end; ++cur) {
    if (cur->a_type == AT_NULL) {
      auxv_end = cur + 1;
      break;
    }
  }

  if (!auxv_end)
    return {};

  return {auxv_start, static_cast<std::size_t>(auxv_end - auxv_start)};
}

// Locate auxv on the live stack pivoted by Sharun via the environ pointer.
[[nodiscard]] Auxv *find_live_auxv() noexcept {
  char **p = environ;
  if (!p)
    return nullptr;
  while (*p)
    ++p;
  return reinterpret_cast<Auxv *>(p + 1);
}

// Patch AT_PHDR, AT_PHNUM, AT_PHENT, and AT_BASE in the auxiliary vector.
void patch_auxv(std::span<Auxv> av, const Objects &o) noexcept {
  for (auto &e : av) {
    if (e.a_type == AT_NULL)
      break;
    switch (e.a_type) {
    case AT_PHDR:
      e.a_un.a_val = reinterpret_cast<std::uintptr_t>(o.exe_phdr);
      break;
    case AT_PHNUM:
      e.a_un.a_val = o.exe_phnum;
      break;
    case AT_PHENT:
      e.a_un.a_val = sizeof(Phdr);
      break;
    case AT_BASE:
      if (o.interp_base)
        e.a_un.a_val = *o.interp_base;
      break;
    default:
      break;
    }
  }
}

[[gnu::constructor]] void patch() noexcept {
  const MapsInfo maps = []() noexcept {
    MapsInfo info;
    File f("/proc/self/maps", "r");
    if (!f)
      return info;

    char *line = nullptr;
    std::size_t cap = 0;
    while (::getline(&line, &cap, f.get()) != -1) {
      unsigned long start, end, offset;
      int path_off = -1;
      if (std::sscanf(line, "%lx-%lx %*s %lx %*s %*s %n", &start, &end, &offset,
                      &path_off) != 3 ||
          path_off < 0)
        continue;

      const std::string_view path(line + path_off);
      if (!info.interp_base && offset == 0 && path.contains("ld-linux"))
        info.interp_base = static_cast<std::uintptr_t>(start);
      if (path.contains("[stack]"))
        info.stack = {static_cast<std::uintptr_t>(start),
                      static_cast<std::uintptr_t>(end)};
    }
    std::free(line);
    return info;
  }();

  const Objects o = [&]() noexcept {
    Objects tmp;
    dl_iterate_phdr(
        [](dl_phdr_info *info, std::size_t, void *data) noexcept -> int {
          auto *out = static_cast<Objects *>(data);
          const std::string_view name = info->dlpi_name ? info->dlpi_name : "";
          // The first entry in glibc's link map is ALWAYS the main program
          if (!out->exe_phdr) {
            out->exe_phdr = info->dlpi_phdr;
            out->exe_phnum = info->dlpi_phnum;
          }
          if (name.contains("ld-linux")) {
            out->interp_base = static_cast<std::uintptr_t>(info->dlpi_addr);
          }
          return 0;
        },
        &tmp);
    if (!tmp.interp_base)
      tmp.interp_base = maps.interp_base;
    return tmp;
  }();

  if (!o.exe_phdr)
    return;

  // Patch both original kernel stack (for Frida) and live stack (for libc/environ)
  Auxv *live = find_live_auxv();
  if (maps.stack.start && maps.stack.end) {
    std::span<Auxv> orig = find_orig_auxv(maps.stack);
    if (!orig.empty())
      patch_auxv(orig, o);
    if (live && live != orig.data())
      patch_auxv({live, kAuxvMax}, o);
  } else if (live) {
    patch_auxv({live, kAuxvMax}, o);
  }
}

} // namespace
