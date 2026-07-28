# Raspberry Pi 4-specific boot workaround, imported only by the Pi 4 hosts.
{ lib, ... }:

{
  # The generic SD image profile enables `hardware.enableAllHardware`, which
  # adds initrd modules for many ARM SoCs (Rockchip, Allwinner, ...) that do
  # not exist in the Raspberry Pi kernel, breaking the initrd build
  # ("modprobe: FATAL: Module dw-hdmi not found in directory ..."). Restrict
  # the initrd module list to what the RPi 4 kernel actually ships (this
  # mirrors nixos-hardware's raspberry-pi-4 module).
  #
  # The Pi 3 does not need this: nixos-hardware's raspberry-pi-3 module
  # instead overlays makeModulesClosure with allowMissing = true.
  boot.initrd.availableKernelModules = lib.mkForce [
    "pcie-brcmstb" # required for the PCIe bus (and thus USB) to work
    "reset-raspberrypi" # required for the VL805 USB firmware to load
  ];
}
