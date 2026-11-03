# Changelog

## 0.1.0 (unreleased)

- First version: 2x mirror of VGA 640x(350..480)x16 planar modes to VMware SVGA II at 32 bpp.
- Real mode (unreal mode) and V86 mode (INT 15h AH=87h, verified before installing).
- INT 10h tracking of mode sets, VBE modes and palette changes; `/U` uninstall, `/Rn` update rate.
