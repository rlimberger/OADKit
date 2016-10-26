# OADKit
A swift class encapsulating a firmware image suitable for uploading to a CC26xx OAD target.

Ti's BLE stack for CC26xx microcontrollers included a method for updating the firmware over the air, called OAD (Over the Air Download). 
These classes provide basic support for the iOS side of this process. This is very much a work in progress and by no means plug and play. 

## Limitations
This targets only CC26xx, off-chip OAD, using the "safe" method, where the first and last page of the flash are untouched. 
These classes may work, or can easily be extended to work with on-chip OAD, but I have not tested this.

## How this works
OAD has 3 basic steps:

    1. write the firmware image information to the target, letting the target know what we are about to upload
    2. write the firmware image (in 16 byte chunks)
    3. reset the target so that the BIM can copy the new firmware image to internal flash.
    
## How to use this class
The FirmwareImage class assumes to be constructed with a string, that is essenctially the hex file that was produced as a result of hexmerge.py. As part of the initialisation, the hex records are parsed (slow) and the start address is determined as well as checksums being calculated

```swift
// read hex file
let data = Data(contentsOf: url)

// trun into string
let hex = String(data: hexData, encoding: String.Encoding.utf8)

// construct FirmwareImage
let img = FirmwareImage(file: hex)
```
When you are ready to start the OAD process, you would first write the image meta information to the target, using the imgIdentifyRequestData() method. When the targets writes 0x000 to the block characteristic, its signals you to start the block transfer. You can now write blocks, using the nextBlock() method. 
```swift
// generate header data
let headerData = img.imgIdentifyRequestData()

// write header to peripheral
peripheral.writeValue(headerData, for: oadCharacteristic, type: .withResponse)

// now you can start writing the blocks. depending on your hardware combination, you may be able to send these
// faster or slower than these defaults:
let NUM_BLOCK_PER_CONNECTION = 2    // send 4, 16 byte blocks per connection
let BLOCK_TRANSFER_INTERVAL  = 0.1  // every 100ms

for _ in 0..<NUM_BLOCK_PER_CONNECTION {
    if let blockData = img.nextBlock() {
        peripheral.writeValue(blockData, for: blockChar, type: .withoutResponse)
    } else {
        // done or some block error
    }
}
```

_Note: you may or may not want to modify your OAD profile to send the next block index as a request to the iphone, and send only that block. This will make the process a lot more failsafe, but will slow things down._ 
