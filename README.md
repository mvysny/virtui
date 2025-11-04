# LazyVirt

A TUI client for virt. Under development. Requires Ruby 3.3+. Currently runs `virsh`.
Currently only tested on Linux host: probably won't work on Windows nor MacOS.

## Setup

Install Ruby:
```bash
$ sudo apt install ruby bundler
```

Run these commands in this project folder, to install project dependencies:
```
$ bundle install
$ bundle exec rake test
```

If `bundle install` fails, try running `bundle config set --global path '~/.gem'`.

- To use lazyvirt over `virsh` binary, run `sudo apt install libvirt-clients`
- To give your user control over virtual machines, add your user to `libvirt` group:
  `sudo usermod -aG libvirt $USER` and log out/log in.
- To setup VMs, install `sudo apt install virt-manager`

## Running

```
bin/lazyvirt
```

## Enabling Ballooning

Without ballooning properly enabled in your guest OS, lazyvirt can't control the amount of memory
available to the guest OS. To enable ballooning:

- Make sure your VM libvirt xml file contains the `<memballoon>` device
- Your guest has QEMU guest agent installed: `sudo apt install qemu-guest-agent`
- Guest agent is running: TODO

More info at [VirtIO Memory Ballooning](https://pmhahn.github.io/virtio-balloon/).

# Future plans

- Implement a full-blown TUI (using `tty-box` and `tty-screen`)
- Automatic balloon control (needs to be enabled)
- Add [libvirt](https://ruby.libvirt.org/) client and a dummy virt client

