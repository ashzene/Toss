Fonts/: Source Serif 4 (SemiBold, 28pt optical size) and Hanken Grotesk (Regular, Medium, SemiBold), the Toss website's typefaces, used by the Settings window. Downloaded from Google Fonts on 2026-10-21. SIL Open Font License 1.1; the licence texts are in Fonts/.
Toss.icon/, Toss.iconset/: Toss app icon. build-release.py compiles Toss.icon with Xcode 26 actool into Assets.car (light, dark, clear, tinted) and Toss.iconset into the fallback Toss.icns.
Sounds/: Toss-Success.aiff (a quick upward "throw" sweep with a soft glint) and Toss-Failure.aiff (two low wooden knocks), made for Toss on 2026-10-24. Synthesized (no samples), 48 kHz 24-bit stereo, −27 LUFS integrated, true peak about −15 dBTP. make-sounds.py here makes the older E/F variants only; do not run it into this folder.

Size-based success cues: Toss-Success.aiff is used below 2 MB; Toss-Success-Medium.aiff from 2 to below 5 MB; Toss-Success-Large.aiff from 5 to below 8 MB; Toss-Success-XLarge.aiff at 8 MB and above. MB = 1,000,000 bytes of the received screenshot. The added cues are synthesized 48 kHz 24-bit stereo AIFF files made for Toss.
DmgWindow/: background.tiff and guide.icns are the native installer window artwork.
