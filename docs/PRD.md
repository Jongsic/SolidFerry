# Product requirements

한국어: [PRD.ko.md](PRD.ko.md)

**SolidFerry** ("Fast, robust, native Android file transfer for Mac") is a macOS app for browsing and transferring files between Android devices (phones and tablets) and a Mac.

## Problem

- macOS doesn't show Android devices in the Finder. Image Capture and Photos only import photos.
- Browsing the folder structure on a device to move just the files you want, or to organize files on the device, requires a separate tool.
- Folders with thousands to tens of thousands of files (such as the camera folder) and multi-GB videos are slow or get interrupted, and after an interruption it's hard to tell what was transferred.
- When a file with the same name already exists, deciding per file whether to overwrite or skip is hard.
- Existing apps each cover part of this, and much of what they do well is the baseline here:
  - **Android File Transfer** (Google) was the official tool. It is discontinued, and could stop for tens of seconds on a large folder.
  - **[OpenMTP](https://github.com/ganeshrvel/openmtp)** is a free, open-source project (Electron), widely used alongside Android File Transfer. It works over MTP. Folders with thousands of files take a while to list, and selecting a range with Shift-click isn't available.
  - **MacDroid** shows the device in the Finder and has both MTP and ADB modes. Copying from the Mac to the device is part of its paid Pro version.
- What's missing is a free, native app that works over both MTP and ADB, stays fast with very large folders, and opens large files straight from the device without downloading them first.

## Users

- Mac users with Android devices: both people who don't enable developer options (MTP) and people who turn on USB debugging (ADB).
- People who back up photos and videos to the Mac, send files from the Mac to a device, or move files between two devices.

## Core features

| Area | Description |
|---|---|
| Connection | Devices appear as soon as they're plugged in over USB. ADB is chosen automatically when USB debugging is on, MTP otherwise (or choose manually). Also connects over Wi-Fi (wireless debugging): pair once with a QR code or pairing code, and it connects automatically from then on |
| Connection problems | Finds the actual reason a connection fails and shows one thing to do (charging-only mode, another app holding the device, waiting for approval on the device, etc.). Safe fixes are done by the app itself |
| Browsing | Finder-like list (name, size, date, kind, sorting), path bar, sidebar (each device's usual folders, SD card or USB drive, and folders added with right-click ▸ Add to Sidebar), tabs and multiple windows, show hidden files. ⌘F searches the folder by name as you type (or with a regular expression), without asking the device again. Space shows the selected file in the viewer and hides it again (Quick Look). ⌫ goes back and ⇧⌫ forward, as in a web browser |
| Transfers | Mac → device, device → Mac, device → device. Drag and drop, copy and paste, or menus all create one job in the same transfer queue |
| Existing files | Skip, overwrite, keep both, only if size or date differs, only if content differs (all files are compared first, then sent), or ask per file. Downloads can just set the date of a file that differs only by its date. A preview shows what will happen before starting, and can be read again (refresh). The dialog is a window of its own: it can be moved and resized for a wider list |
| Transfer queue | One section per device: each device runs its jobs one at a time, devices run side by side. Progress and speed (averaged over a few seconds); when nothing moves, what it's waiting for (the device, this Mac's disk). Pause, resume, cancel per job, with "Pausing…" until it has stopped; list of failed files with retry. Continues after the app is reopened. When the connection drops, waits and continues once reconnected |
| Transfer results | Double-click a job: where from and where to, its options, times and average speed, and for every file what was there, what came in, what was done (copied, skipped and why, overwritten, kept both under which name, date set, failed and why) and what's there after, with hashes when compared. Kept until removed from the transfers window |
| Keeping dates | When sending to a device that changes the dates of received files, files are sent bundled in a single ZIP; extracting it on the device keeps the original dates |
| Preview and viewer | A preview panel beside the list (photos, a video frame with duration and resolution, text, the first page of a PDF, album art, all file information). A viewer window for photos, video and audio that streams from the device: even a multi-GB video opens and seeks immediately, without downloading it first. Open in another app |
| Organizing on the device | New folder, rename, batch rename (find and replace, numbering, case), delete |
| Settings | Text size per part of the window, toolbar style, Wi-Fi auto-connect, keeping the Photos service from claiming the device first |
| Languages | English, Korean |

## Quality bar

- **Never lose existing files.** The default leaves existing files untouched. An overwrite replaces the file only after the new file has been fully received. An interruption never leaves the original replaced by a half-written file.
- **Fast.** Lists are drawn as soon as the first part arrives. Transfer speed approaches the limit of the connection (USB 2/3, Wi-Fi). Fast with many small files too.
- **Never hang the device.** Approaches that can hang a device are avoided rather than tried.
- **Messages state only the result and what to do.** Internal behavior is not shown.
- **Easy to set up.** If ADB is missing, the app explains and downloads it (Google's distribution or Homebrew). Without ADB, the app still works over MTP.

## Out of scope

- Thumbnails and media info in the list (to keep listing fast)
- Installing an app on the device (nothing is installed on the device)
- iPhone, Windows, cloud storage

## Distribution

- Open source (MIT). Released as a DMG on GitHub, outside the Mac App Store (direct access to the adb server socket and USB requires turning off the sandbox)
- Minimum macOS 14

## Open questions

- Whether to support two-way automatic sync (keeping folders in sync)
- The lowest Android version to officially support
