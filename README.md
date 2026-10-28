# GhostLock for HONOR LDY-AN00

Temporary root access for the **HONOR Magic8 Pro Air (LDY-AN00)** using
CVE-2026-43499, also known as GhostLock. The launcher builds the exploit from
source and opens a root shell over an authorized ADB connection.

**Status:** verified on one physical device with the exact firmware below.
Root and permissive SELinux last until reboot. The bootloader can remain locked;
this tool does not unlock it or install persistent root.

For bootloader patching after obtaining root, see the companion
[LK unlock repository](https://github.com/iodn/honor-ldy-an00-lk-unlock).

> **Known stability issue:** the exploit leaves modified RT-mutex state behind.
> A delayed kernel panic has been observed. Run only one exploit chain per boot,
> save important data first, and reboot when finished.

## Supported configuration

| Item | Required value |
| --- | --- |
| Phone | HONOR Magic8 Pro Air |
| Model / stock device name | `LDY-AN00` / `HNLDY-M` |
| SoC | MediaTek MT6993 |
| Firmware | `10.0.0.113(C00E100R101P1)` |
| Android | 16 |
| Kernel | `6.12.38-android16-5-g4b3671e1f5b7-abogki460618149-4k` |
| Architecture | ARM64, 4 KB pages |

Other devices, firmware versions and kernel builds are unsupported. The launcher
checks the model and kernel, but those checks do not establish compatibility with
other firmware. Kernel addresses and structure offsets are specific to this port.

## Quick start

All commands below run on a **Linux computer**, from this repository's root
folder, unless marked as phone-shell commands. The tested host architecture is
x86_64. No APK installation is required.

### 1. Install the tools

On Debian or Ubuntu:

```bash
sudo apt update
sudo apt install adb gcc-aarch64-linux-gnu libc6-dev-arm64-cross
```

Download and extract this repository, or clone it after publication. Open a
terminal in the folder containing `root.sh`.

### 2. Connect the phone

Enable **Developer options > USB debugging**, connect the USB cable and accept
the debugging authorization prompt on the phone.

```bash
adb devices
adb shell getprop ro.product.model
adb shell uname -r
```

The device must show `device`, not `unauthorized` or `offline`. Check the model,
kernel and firmware against the table above before continuing.

### 3. Start the root session

Save open work on the phone first: the launcher **may reboot it automatically**
to obtain a clean boot.

```bash
bash root.sh
```

Keep the terminal open. Unlock the phone again if it reboots. The exploit usually
takes **one to six minutes**; elapsed time varies with the timing-based leak.
The launcher builds its binaries, uploads them to `/data/local/tmp`, checks
available on-device SHA-256 results against the local builds and opens a shell.

When the root prompt appears, run these commands **inside that phone shell**:

```sh
id
getenforce
```

Expected output includes:

```text
uid=0(root) gid=0(root) groups=0(root) context=u:r:kernel:s0
Permissive
```

### 4. Use root from another terminal

A new ordinary `adb shell` still starts as UID 2000; `adbd` itself is unchanged.
The launcher also starts a temporary `su` broker. From another host terminal:

```bash
adb shell /data/local/tmp/su -c 'id'
```

For an interactive root shell:

```bash
adb shell -t /data/local/tmp/su
```

Use this broker instead of running the exploit a second time. It accepts only
UID 0 and the ADB shell UID 2000 using `SO_PEERCRED`. While it is running,
authorized ADB hosts can obtain root; ordinary application UIDs are rejected.

### 5. Finish the session

```bash
adb reboot
```

Reboot clears the root session, broker process and permissive state. Uploaded
files may remain in `/data/local/tmp`; their presence does not provide root on
the next boot. Any later exploit run must start on a fresh, supported boot.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| `unauthorized` in `adb devices` | Unlock the phone and accept its debugging prompt. |
| No device or `offline` | Check USB debugging, cable, host USB permissions and ADB connection. |
| Model or kernel mismatch | Stop. The port is specific to the supported configuration. |
| More than one device connected | Use `bash root.sh --serial SERIAL`, replacing `SERIAL` with the intended device's ADB identifier. |
| Leak attempts fail or the shell never appears | Save the terminal output and reboot before retrying. Do not start another chain on the same boot. |
| A new ADB shell is not root | Expected. Use `/data/local/tmp/su` after the launcher succeeds. |
| `su: root daemon not running` | The broker is unavailable. Do not rerun the exploit on the same boot; start again after a reboot. |
| Phone panics, freezes or restarts | Stop using the session. A stale-waiter panic is a known limitation; a forced restart may be necessary. |
| Root disappears after reboot | Expected. Root is temporary. |

The launcher tracks the last attempted boot ID in its host cache. In automatic
mode it reboots on the first recorded use or if the current boot was already
used. It also refuses to treat a permissive boot as a clean starting point.
This bookkeeping cannot eliminate the underlying kernel-corruption risk.

## Launcher options

```bash
bash root.sh --help
```

| Option | Behavior |
| --- | --- |
| `-s`, `--serial SERIAL` | Select one ADB device. |
| `--reboot` | Always reboot before the exploit. |
| `--no-reboot` | Skip reboot; only appropriate when no chain has run on this boot. |
| `--force` | Bypass model/kernel checks; does not make an unsupported kernel compatible. |
| `-h`, `--help` | Show help without running the exploit. |

Do not use `--force` or `--no-reboot` to work around a failed compatibility or
clean-boot check. The abandoned `rootadbd` / `ROOT_TARGET>=2` mode is unsupported
and caused a stack-canary panic during development.

## Build without running

```bash
bash build.sh
```

This compiles the exploit and broker without connecting to the phone. Output is
stored outside the checkout:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/ghostlock-ldy-an00/device_root_aarch64
${XDG_CACHE_HOME:-$HOME/.cache}/ghostlock-ldy-an00/su
```

The phone-tested exploit binary had SHA-256:

```text
d0d72f0379d91971152cac7a970001c6b1057296ea5b38b87866baa21e4de9ab
```

Different toolchains can produce a different hash. The launcher reports that
reference difference and uses the local build; it is not a guarantee that every
recompiled binary behaves identically on hardware.

| Source | Purpose |
| --- | --- |
| [root.sh](root.sh) | Target checks, clean-boot handling, build, upload and launch |
| [build.sh](build.sh) | Static AArch64 cross-compilation |
| [device/](device/) | On-device launchers and broker startup |
| [su/su.c](su/su.c) | Temporary root broker and client |
| [exploit/device_root.c](exploit/device_root.c) | Device-specific exploit |
| [exploit/kernelsnitch/](exploit/kernelsnitch/) | Timing-leak support headers |

## Technical details

<details>
<summary>Exploit mechanics and device-specific kernel offsets</summary>

The underlying bug is in the RT-mutex priority-inheritance code. On this kernel, `remove_waiter()` clears `current->pi_blocked_on` during the futex `EDEADLK` rollback, rather than clearing the blocked waiter's task field.

The relevant sequence from `kernel/locking/rtmutex.c` is

```c
_raw_spin_lock(current->pi_lock);
*(u64 *)(current + 0xa18) = 0;
_raw_spin_unlock(current->pi_lock);
```

The actual blocked task still points to a `rt_mutex_waiter` that has gone stale. That waiter originally lives on another task's kernel stack. By keeping the victim in the right syscall state and controlling the stack data subsequently copied there, the exploit makes `rt_mutex_adjust_prio_chain()` process a forged waiter. The forged RB-tree leads to writes through `rb_erase()`.

The port uses that primitive to find the child's task, replace its credentials and disable SELinux enforcement. The escalated child then starts a shell attached to the original ADB terminal.

### Finding the child's `mm_struct`

The first stage uses KernelSnitch's futex-hash timing leak. On this phone, the hash size is `roundup_pow_of_two(256 * possible_cpus)`, which works out to 2048 buckets. Eight CPUs are online. The child sets up a pile of 4096 threads, and timing collisions between futex buckets are used to estimate the address of its `mm_struct`.

The `mm_struct` allocations have a `0x500` stride in order-2 slabs, with 12 objects per slab. The port uses a two-phase collision growth check and a voting cross-check to reject weak candidates. This is the only KASLR-independent pointer the exploit needs. Other addresses come from image-relative symbols plus the slide, or from linear-map aliases of link-time symbols.

This stage was also the slowest part during testing. Depending on the boot, the leak took 53 to 317 seconds and succeeded on attempts 1 through 7.

### Holding the victim in `pselect6`

The victim calls `pselect6(320, ...)` with one socket duplicated across file descriptors 3 through 319. The resulting fd-set buffers sit in the grow-down gap of the main stack. `do_select` copies three result bitmaps into a region overlapping the stale waiter, giving the attacker control over the words that `rt_mutex_adjust_prio_chain()` later reads.

To hold that memory in place, the victim faults during the result copy while another thread holds `mmap_write_lock` through a prefaulted `munmap`. The trigger is `sched_setattr(victim)`, but it is only issued after `/proc/self/task/<tid>/stat` reports state `D`, with `select_returned=0` and `holder_done=0`, inside the measured holder window. The cutoff is `HOLDER_MIN_US=25000`.

That check was added after an early-returning `pselect` victim caused a stale-waiter panic on the phone. If the timing check fails, the process parks instead of exiting and walking the damaged PI state.

### The write primitive

The shaped waiter reaches `rb_erase()` and produces two stores.

```c
*(target) = value;
*(value) = target - 8;
```

The second write happens when `value` is nonzero. A zero value gives a clean eight-byte zero store. Otherwise, the location pointed to by `value` gets overwritten as a side effect, which matters when selecting targets. The fake RB parent must be black, so the targets are eight-byte aligned to avoid entering the red-parent fixup path.

Each write uses a scratch `rt_mutex_base` in a zeroed kernel page. Scratch slots rotate with `g_write_seq % 120` because the dead waiter remains attached to the slot after the chain completes.

### Reading kernel memory through the UUID sysctl

The read primitive repoints the `.data` entry used by `/proc/sys/kernel/random/uuid`. On the tested image, `random_table[5].data` is at link-time address `0xffffffc08250b590`.

For a read at `Q`, the exploit points this field at `Q - 8` and opens the sysctl file. `proc_do_uuid()` formats 16 bytes, exposing the qword at `Q..Q+7`. The secondary store places a sentinel at `Q - 8`, so the read also damages the preceding eight bytes. The port uses shifted windows to verify sensitive writes, repairs `mm->ioctx_table` and `real_cred`, and restores `random_table[5].data = NULL` afterwards.

The first byte at `Q` cannot be zero for this read method. Otherwise `proc_do_uuid()` generates a new random UUID into the region instead of formatting the existing data.

### Replacing the credentials

With the child's `mm_struct` address known, the chain reads `mm->owner` to get its `task_struct`. It then writes the linear-map alias of `init_cred` into `real_cred` and `cred`, at task offsets `0x8f8` and `0x900`. The link-time address of `init_cred` for this image is `0xffffffc082402cb0`.

The child verifies that its real and effective user and group IDs are zero. The write's secondary store changes `init_cred.usage`, which did not prevent the use of that immortal credential object in these tests.

At this point the child has UID 0 and full capabilities, but its SELinux SID is `u:r:kernel:s0`. With SELinux still enforcing, it cannot execute `/system/bin/sh`, write the selinuxfs enforcement file or load a module. The command and evidence handshake therefore uses a shared-memory ring set up before the fork. An earlier pipe-based handshake failed with `EACCES` after the SID change.

### Disabling SELinux enforcement

The port uses an aligned PI write to change the global `selinux_state.enforcing` byte. The target's link-time address is `0xffffffc0826663c8`; in the verified phone boot its linear-map alias was `0xffffff80026663c8`.

The value is selected from an otherwise unused `efi_x_array` alias. In the tested run, it was `0xffffff8002691500`. Its low byte is zero, which clears `enforcing`; the next byte remains nonzero, keeping `initialized` set. The remaining bytes overwrite adjacent `checkreqprot` and `policycap[]` state. The secondary write lands in unused `efi_x_array` BSS.

That is not a general-purpose SELinux patch. It relies on the exact layout observed on this kernel. After the PI write, the child opens `/sys/fs/selinux/enforce` for writing and writes `0` through the normal interface as a check.

Once enforcement is off, the escalated child can run `/system/bin/sh -i` on the ADB session's inherited standard streams. The parent exploit process stays parked rather than tearing down the stale RT-mutex state.

### Device-specific addresses

These are the link-time values and offsets used in the tested build, not a portable Android layout.

```text
init_cred                     0xffffffc082402cb0
selinux_state.enforcing       0xffffffc0826663c8
random_table[5].data          0xffffffc08250b590
efi_x_array                    0xffffffc082690540
init_task                     0xffffffc0823ecf00
kernel image link base        0xffffffc080000000

task_struct.real_cred         0x8f8
task_struct.cred              0x900
task_struct.pi_lock           0x9ec
task_struct.pi_blocked_on     0xa18
task_struct.pid               0x708
task_struct.tgid              0x70c
task_struct.stack_canary      0x710
task_struct.real_parent       0x718
task_struct.parent            0x720
task_struct.group_leader      0x748

mm_struct.pgd                 0x68
mm_struct.ioctx_table         0x408
mm_struct.owner               0x410

KPHYS                         0x80000000
PHYSOFF                       0x80000000
```

The symbol aliases follow `PAGE_OFFSET + (KPHYS - PHYSOFF) + (link_time - 0xffffffc080000000)`. Because the physical load address and memstart are both `0x80000000`, the delta is zero. Addresses in the `0xffffffc0` range are link-time image addresses before the boot's KASLR slide is applied.

</details>

## Support and contributions

Report issues through the repository's Issues page after publication. Include
the firmware, kernel version, command used and relevant terminal output. Remove
serial numbers, credentials and other personal information before sharing logs.
Compatibility reports must distinguish successful root from a stable session;
one successful run does not establish reliability on another device.

## Credits

The port builds on published GhostLock and KernelSnitch research, including
[gitchw/ghostlock-cve-2026-43499](https://github.com/gitchw/ghostlock-cve-2026-43499)
and [shubhampathak65/CVE-2026-43499](https://github.com/shubhampathak65/CVE-2026-43499).
The KernelSnitch-derived headers retain their upstream notices, including the
Bob Jenkins / Jozsef Kadlecsik jhash notice in `futex_hash.h`.

SELinux and post-exploit research consulted public ports by JoinChang, PeronGH,
ghost-hoock and Bugel, plus H80GT, `YuKongA/ghostlock-app`,
`JoinChang/ghostlock-oneplus`, `JingMatrix/pixel-ksu-root`, and the NVIDIA Shield
port. This port uses its own userspace broker. Device-specific kernel and BTF
analysis used Ghidra MCP.

## License

MIT License. Copyright (c) 2026 the ghostlock-ldy-an00 authors.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

The KernelSnitch-derived headers in `exploit/kernelsnitch/` keep their own upstream notices, including the jhash notice in `futex_hash.h`. This is research software supplied as is for authorized testing on devices you own.
