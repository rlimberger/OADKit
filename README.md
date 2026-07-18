# OADKit

A Swift class encapsulating a firmware image suitable for uploading to a CC26xx OAD target.

TI's BLE stack for CC26xx microcontrollers includes a method for updating firmware over the air, called OAD (Over the Air Download). These classes provide basic support for the iOS side of this process. This is very much a work in progress and by no means plug and play.

## Limitations

This targets only CC26xx, off-chip OAD, using the "safe" method, where the first and last page of the flash are untouched. These classes may work, or can easily be extended to work with on-chip OAD, but that has not been tested.

## How this works

OAD has 3 basic steps:

1. Write the firmware image information to the target, letting the target know what we are about to upload
2. Write the firmware image (in 16-byte chunks)
3. Reset the target so that the BIM can copy the new firmware image to internal flash

## How to use this class

`FirmwareImage` is constructed from a hex string that is essentially the hex file produced by `hexmerge.py`. During initialization, the hex records are parsed, the start address is determined, and checksums are calculated.

```swift
// Prefer the URL convenience initializer
guard let img = FirmwareImage(url: url) else {
    // failed to read or decode hex file
    return
}

// Or construct from a hex string:
// let hex = try String(contentsOf: url, encoding: .utf8)
// let img = FirmwareImage(hexString: hex)
```

When you are ready to start the OAD process, first write the image meta information to the target using `imgIdentifyRequestData()`. When the target writes `0x0000` to the block characteristic, it signals you to start the block transfer. You can then write blocks using `nextBlock()`.

```swift
// Generate header data
let headerData = img.imgIdentifyRequestData()

// Write header to peripheral
peripheral.writeValue(headerData, for: oadCharacteristic, type: .withResponse)

// Start writing blocks. Depending on your hardware combination, you may be able
// to send these faster or slower than these defaults:
let numBlocksPerConnection = 2  // send 2 × 16-byte blocks per connection
let blockTransferInterval = 0.1 // every 100ms

for _ in 0..<numBlocksPerConnection {
    if let blockData = img.nextBlock() {
        peripheral.writeValue(blockData, for: blockChar, type: .withoutResponse)
    } else {
        // done, or block error
    }
}
```

_Note: you may want to modify your OAD profile to send the next block index as a request to the iPhone and send only that block. This makes the process more failsafe, but will slow things down._

## Installation

### Swift Package Manager

Add this repository as a package dependency in Xcode, or in `Package.swift`:

```swift
.package(url: "https://github.com/rlimberger/OADKit.git", branch: "master")
```
