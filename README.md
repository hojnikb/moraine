# Moraine -- alpinelinux based inference distro for BC-250

**Your retired crypto-mining board has been reskilled. It does AI now.**

The AMD BC-250 is half a PlayStation 5 that spent its formative years in a
warehouse, hashing numbers nobody needed, screaming through fans, never once
allowed to play a game. Then the mining boom ended and it was laid off in
bulk. It now sells for less than a nice dinner, it has 16 GB of fast shared
memory, and it would really like to feel useful again.

Moraine is its career-change programme. Flash a USB stick, boot, pick a
model, and the board answers questions over an OpenAI-compatible API. It's a
minimal Linux appliance built on [Alpine Linux](https://alpinelinux.org) with
exactly one personality trait: **every megabyte the operating system doesn't
use is a megabyte the model gets.** It will bring this up at parties.

> **Status:** early and experimental. It boots, it loads models, it answers
> questions. Occasionally it answers them *correctly*. Rough edges are
> included free of charge. Issues and pull requests are very welcome;
> complaints about the jokes will be read aloud to the board, which has
> feelings now.

---

## Features

- **Boots straight into an LLM server.** [llama.cpp](https://github.com/ggml-org/llama.cpp)'s
  `llama-server` on the Vulkan backend: `/v1/chat/completions`, `/v1/models`
  and friends, plus an optional web chat UI for when you want to talk to it
  like a person instead of like a `curl` command.
- **An operating system on a strict diet.** musl, busybox, OpenRC. No udev
  daemon, no dbus, no journald, no NetworkManager, no forty-seven services
  negotiating with each other at boot. Mesa is built RADV-only: no LLVM, no
  OpenGL, no X11, no Wayland. A headless box that serves tokens has no reason
  to know what a window is, and we intend to keep it that way. `/tmp` lives on
  disk and there is no swap. RAM is for models. RAM has always been for models.
- **GPU memory that sizes itself.** At boot, before the GPU driver has even
  had its coffee, the GTT pool (system RAM the GPU may borrow) is set to
  "all of it, minus a small reserve so Linux can still breathe". It works with
  whatever VRAM split your BIOS picked, including the ones you picked at 2 a.m.
- **24 compute units by default, 40 if your board has them.** The chip has
  40 CUs, 16 of them switched off at the factory, like a sports car sold with
  the back seats bolted shut. Moraine ships with the seats bolted, because
  some boards had them removed for a reason. A patched `amdgpu` module can
  unbolt them: flip on 40 CU mode in `moraine-setup`, reboot, and if a few of
  the unlocked units turn out to be duds, mask those WGPs from the same menu
  and never speak of it again.
- **A GPU governor with work-life balance.** The SMU-based
  [cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor/tree/smu)
  raises clocks when there's work and lowers them when there isn't, which is
  more than can be said for most of us. Out of the box it's given exactly
  one voltage/frequency point, so it holds the board's stock 1500 MHz, the
  same as a board with no governor at all. Give it more points (and a wider
  range) from a menu and it starts scaling; take them away and it goes back
  to being very calm.
- **`moraine-setup`: menus instead of config files.** Because nobody's first
  instinct at 11 p.m. is to hand-edit `/etc/conf.d`.
  - a model picker that finds `.gguf` files in `/models` and on USB drives,
    with a folder browser and download-from-URL
  - memory math done for you: weights + KV cache + compute buffers vs. what the
    GPU actually has, read straight from the GGUF metadata. It understands
    GQA, sliding-window, hybrid (Qwen3-Next style) and MLA models, so it won't
    have a panic attack over KV cache that doesn't exist
  - KV cache precision, context length, micro-batch, slots, flash attention,
    reasoning on/off, vision projector, web UI
  - 40 CU mode and WGP masking, governor points, GTT pool size
  - start/stop the server, start at boot, benchmark, drive speed test, and a
    GPU monitor (`amdgpu_top`) for staring at numbers while pretending to work
- **A loading bar that tells the truth.** Real read throughput and time left,
  at boot and in the setup tool. If it says three minutes, it's because your
  USB stick is slow, not because the bar is emotionally unavailable. At boot,
  press **D** to give up gracefully and stop it trying again.
- **Designed to survive your ambition.** Tried a 70B model "just to see"? We
  saw you coming.
  - A pre-flight check refuses models bigger than GPU memory before they try.
  - llama-server volunteers as first victim for the out-of-memory killer, so
    SSH lives to tell the tale.
  - Drop a `skip-llama` file on the boot partition and the next boot starts
    without the server, like nothing happened.
- **Configurable from literally any computer.** The boot partition is plain
  FAT32, the one filesystem every operating system has agreed to tolerate.
  Drop in `authorized_keys`, a `root-password` or a `llama-server.conf` from
  Windows, macOS or Linux before first boot.
- **No bootloader.** Kernel, initramfs and command line are one Unified Kernel
  Image loaded directly by the UEFI firmware. No menu, no timeout, no five
  seconds of staring at a list with one entry on it.
- **A login prompt with a sense of humour.** Every boot picks a fresh quip
  for the console login prompt and the SSH banner, from a hand-picked list
  of things a retired mining board might say. Edit
  `/usr/share/moraine/quips.txt` to write your own.
- **A quiet boot.** Kernel chatter stays in `dmesg` instead of on your screen,
  including this chip's habit of announcing, once per CPU core, that its
  RDSEED instruction can't be trusted. We heard you the first time.
- **nano included,** for people who have a life outside `vi`.

## Hardware

| | |
|---|---|
| Board | AMD BC-250 (ASRock mining board, "Cyan Skillfish" / gfx1013 APU) |
| Firmware | UEFI boot. A small BIOS VRAM split (e.g. 512 MB) leaves the most for the GTT pool |
| Storage | USB stick (use a USB 3.0 port, unless waiting is your hobby) or the M.2 slot |
| Network | Onboard RTL8168H gigabit Ethernet, DHCP |
| Display | Optional. Plug into DisplayPort to watch it boot, or trust it |

The board draws well over 150 W with all 40 CUs busy. It grew up in a mining
rack with industrial airflow and a hearing-protection policy, not on a
bookshelf. Give it a proper PSU and a fan that means business.

## Quick start

1. **Download** `moraine.release version.zip` and `SHA256SUMS` from
   [Releases](../../releases) and verify, because trust is earned, not
   downloaded:
   ```sh
   sha256sum -c SHA256SUMS --ignore-missing
   ```
2. **Flash** it to a USB stick. Everything on the stick goes away forever:
   ```sh
   xz -dc moraine.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
   ```
   Check `sdX` twice. `dd` is known as "disk destroyer" in many households,
   has no undo button, and holds grudges. balenaEtcher, or Rufus in *DD mode*,
   also work.
3. *(Optional)* Open the small FAT partition `MORAINE` and add SSH keys
   (`moraine/authorized_keys`) or a password (`moraine/root-password`).
4. **Boot** the BC-250 from the stick (UEFI). On first boot the root partition
   stretches to fill the whole drive, like a cat on a warm bed.
5. **Log in** as `root` / `moraine`. Yes, really. No, it's not staying that way:
   the setup tool nags you to change it immediately, and then offers the
   wizard.
6. **Copy a model** and pick it in the wizard:
   ```sh
   scp model.gguf root@moraine:/models/
   ssh -t root@moraine moraine-setup
   ```
7. **Say hello:**
   ```sh
   curl http://moraine:8080/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"messages":[{"role":"user","content":"Hello!"}]}'
   ```
   Any OpenAI-compatible client works with base URL `http://<box>:8080/v1`.
   Congratulations: your API bill is now your electricity bill, and your
   electricity bill would like a word.

`moraine-status` shows memory, GPU state, storage link speed and server health
on one screen, for when you want to know what it's doing without asking it
and getting a 400-word answer.

## What's inside

| Component | Version / source |
|---|---|
| Base system | Alpine Linux 3.24 (musl, busybox, OpenRC, dropbear) |
| Kernel | Alpine `linux-lts` 6.18 + `amdgpu` rebuilt with the [BC-250 40 CU unlock patch](https://github.com/duggasco/bc250-40cu-unlock) |
| GPU driver | Mesa 26.2 (mainline), RADV only, built without LLVM |
| Inference | llama.cpp (mainline), Vulkan backend, statically linked `llama-server` / `llama-bench` |
| GPU governor | [cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor/tree/smu), `smu` branch |
| Monitoring | [amdgpu_top](https://github.com/Umio-Yasuno/amdgpu_top) (from Alpine edge/testing) |
| Firmware | `linux-firmware-amdgpu`, `linux-firmware-rtl_nic`, and absolutely nothing else |

Everything is a regular Alpine package, built from source with `abuild` and
signed. The image carries its own package repository, so `apk` works like it
does anywhere else. Alpine edge/testing is enabled as a *tagged* repo
(`apk add foo@testing`): the shiny packages are within reach, but they only
come in when you invite them by name, like vampires.

## When the model doesn't fit

It happens to the best of us. Your options, sorted from "calm" to "it's
3 a.m. and the fans sound like a jet":

- **At boot:** press **D** on the console progress bar. It cancels the load
  and stops it trying again at every boot like an optimistic toddler.
- **In `moraine-setup`:** "LLM server: RUNNING – stop it and unload the
  model" once it's up, or set "Start LLM server at boot" to no.
- **Over SSH:** `moraine-llama-cancel`. It works even while the service is
  halfway through starting, when a polite `rc-service stop` would just stand
  there saying "it's starting, please wait". Add `--disable` to stop it
  starting at boot.
- **From another computer, when the box is having a moment:** put an empty
  file named `skip-llama` in the boot partition's `moraine/` folder. The next
  boot skips the server once, and you can go pick a smaller model with your
  dignity mostly intact.

## Building from source

Any x86_64 Linux host with root (or a privileged container) can build the
image. All the work happens inside an Alpine builder chroot under `work/`,
so your host only needs `sh`, `curl`, `tar`, `mount` and `chroot`, and stays
as tidy as it was before. Tidier, probably, than your desk.

```sh
git clone https://github.com/<user>/moraine.git
cd moraine
$EDITOR config.env          # optional: hostname, password, keys, defaults
sudo ./build.sh             # builder -> packages -> rootfs -> image
# output: work/out/moraine.img
```

Individual stages: `./build.sh packages [pkg...]`, `rootfs`, `image`,
`shell` (enter the builder chroot), `clean`. Mesa, llama.cpp and the `amdgpu`
module are the slow builds. Now is a good time to make coffee. Possibly
dinner. llama.cpp generates its Vulkan shaders one by one and would like you
to meet each of them personally.

```
config.env                      build settings (config.local overrides)
build.sh                        builder / packages / rootfs / image
overlay/                        static files copied into the rootfs
packages/
  moraine-base/                 GTT sizing, first-boot growth, boot-partition import,
                                llama-server service, load progress, UKI tooling, status
  moraine-setup/                  menu-driven setup tool + GGUF metadata reader
  bc250-amdgpu-40cu/            patched amdgpu.ko, pinned to the linux-lts version
  cyan-skillfish-governor-smu/  GPU governor + service + config
  llama-cpp-vulkan/             llama.cpp server/bench
  mesa-radv-minimal/            RADV-only Mesa
```

The kernel module package is pinned to an exact `linux-lts` version, so
`apk upgrade` can't swap the kernel out from under the patched `amdgpu` and
quietly demote you back to 24 CUs. `build.sh` refuses to build if the pin
doesn't match Alpine's current kernel, and tells you exactly which number to
bump, like a very specific parrot.

## Caveats (short, important, mildly stern)

- **40 CU mode** (off by default) runs the chip beyond its factory
  configuration: more heat, more power, and not every board has 40 healthy
  units. Test it, and mask WGPs that misbehave. Clocks stay at the stock
  1500 MHz by default, because 2 GHz on 40 CUs turns the heatsink into a
  cooking surface.
- **Custom voltage points** can damage hardware. The setup tool checks ranges
  and warns above 1000 mV, but it's a menu, not a parent. That part's on you.
- **Default credentials** (`root` / `moraine`) exist so you can log in the first
  time. Change them. The internet is mostly made of people who didn't.
- **Memory estimates are estimates.** They're usually close. The server log
  has the real numbers and no sense of humour.

## Acknowledgements

Moraine is mostly other people's excellent work, arranged with enthusiasm:

- [Alpine Linux](https://alpinelinux.org), the base system and build tooling
- [llama.cpp](https://github.com/ggml-org/llama.cpp) and [Mesa](https://mesa3d.org)
- [filippor/cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor/tree/smu), the SMU-based GPU governor
- [duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock), the 40 CU `amdgpu` patch
- [WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager), the live CU/WGP routing research
- [Umio-Yasuno/amdgpu_top](https://github.com/Umio-Yasuno/amdgpu_top)
- The BC-250 community documentation, e.g.
  [mothenjoyer69/bc250-documentation](https://github.com/mothenjoyer69/bc250-documentation)

## License

The build scripts, setup tools and service files in this repository are
licensed under the terms in [LICENSE](LICENSE). Every packaged component
keeps its own upstream license (GPL-2.0 for the kernel module, MIT for Mesa
and llama.cpp, and so on).

Moraine is an independent project, not affiliated with or endorsed by AMD,
ASRock, Sony or the Alpine Linux project. None of them asked for this. Some
of them may not know yet.

---

## Disclaimer: an AI built this

Moraine's build system, packages, scripts, setup tool and this README were
written by **Claude**, an AI model made by [Anthropic](https://www.anthropic.com),
in conversation with the project's maintainer. The human decided what to
build, tested the images on a real BC-250, reported what broke, and asked for
fixes until it stopped breaking. The AI wrote the code and the jokes, so you
know exactly who to blame for the jokes.

What that means for you:

- The code has been tested by a human on real hardware, but it has **not been
  audited**. Treat it like any other hobby project from the internet: read
  the scripts before running them as root, especially `build.sh`.
- Some parts were verified only in a build environment, not on every board
  revision, BIOS or USB stick in existence. If something behaves oddly on your
  hardware, please open an issue; it's probably not you.
- Moraine is provided **as is, without warranty of any kind**. Unlocking
  compute units and changing clocks or voltages is done at your own risk.

The AI would like to add that it enjoyed the project. The BC-250 was not
consulted, but seems happier.

Human edit: Any complaints should go straight to Dario. If this causes your wife to cheat on you or your kids hate your, you know who to blame.
