<p align="center">
  <img src="docs/images/banner-dark.png" alt="Toss. Press two keys. Your iPad right in the chat." width="792">
</p>

Toss is a Mac menu-bar app that drops a screenshot of your iPad into the ChatGPT, Codex or Claude chat you have open. It only adds the picture to your draft; you still press Send.

### Press two keys. Your iPad right in the chat.

<p align="center">
  <img src="docs/images/demo-shortcut-dark.gif" alt="Left and right Option together add the iPad screenshot to the open ChatGPT draft." width="792">
</p>

### Works wherever the chat window is

<p align="center">
  <img src="docs/images/demo-any-window-dark.gif" alt="A past paper is in front. Both Shift keys go down, Claude comes to the front and the iPad screenshot lands in its input box." width="792">
</p>

### Wired or wireless, your call

<p align="center">
  <img src="docs/images/demo-usb-wifi-dark.gif" alt="A USB cable plugs into the Mac and the Toss menu shows the iPad connected over USB; unplug it and Toss is back on Wi-Fi." width="792">
</p>

## Shortcuts

| Press together | Goes to |
| --- | --- |
| Left <kbd>⌥ Option</kbd> + right <kbd>⌥ Option</kbd> | ChatGPT / Codex |
| Left <kbd>⇧ Shift</kbd> + right <kbd>⇧ Shift</kbd> | Claude |

Toss brings the right chat window forward first, then captures and attaches. Works over USB or Wi‑Fi, whichever is connected.

## Get started

1. Download the latest [release](https://github.com/ashzene/Toss/releases/latest) and drag Toss into Applications.
2. Connect your iPad with a USB data cable the first time, tap **Trust** and turn on **Developer Mode**. Toss guides you through it.
3. After that, pairing is done. Toss reconnects by itself.

Needs an Apple silicon Mac with macOS 14+, and an iPad with iPadOS 17+ (17.4+ for USB).

## License

[MIT](LICENSE), except the capture service in [`Backend/`](Backend), which builds on [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) and is [GPL-3.0](Backend/LICENSE).
