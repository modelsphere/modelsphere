#!/usr/bin/env bash
# Clear the PCIe ACS redirect bit on every bridge that has it set.
#
# ACS (Access Control Services) forces peer-to-peer DMA up to the root complex
# and through the IOMMU, which destroys GPUDirect RDMA throughput -- and worse,
# with NCCL_NET_GDR_LEVEL above 0 it can deadlock NCCL during initialisation:
# Gloo connects, every rank prints its NCCL version, and then nothing. Plain IB
# RDMA between host buffers is unaffected, so `ib_write_bw` runs at full speed
# on a node where GDR hangs -- which is why this is worth clearing in advance
# rather than diagnosing later.
#
# This is a live register write: BIOS and PCIe re-enumeration set ACS again on
# every boot. It is therefore installed as a systemd oneshot (see
# disable-acs.service) rather than run once by hand.
#
# Prints the number of bridges it changed, so a caller can report "changed" only
# when something was actually set.
#
#   bash disable_acs.sh          # clear, print a count
set -u

command -v setpci >/dev/null 2>&1 || { echo "setpci not found (pciutils)" >&2; exit 1; }

cleared=0
for bdf in $(lspci -D | awk '{print $1}'); do
  # ECAP_ACS+0x6.w is the ACS control register. A device without the capability
  # errors here, which is the common case -- skip it quietly.
  ctl=$(setpci -s "$bdf" ECAP_ACS+0x6.w 2>/dev/null) || continue
  [ -z "$ctl" ] && continue
  [ "$ctl" = "0000" ] && continue
  setpci -s "$bdf" ECAP_ACS+0x6.w=0000 2>/dev/null || continue
  cleared=$((cleared + 1))
done

echo "acs_cleared=$cleared"
