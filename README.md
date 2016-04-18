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
    
## How to use these classes
The FirmwareImage class assumes to be constructed with a string, that is essenctially the hex file that was produced as a result of hexmerge.py. As part of the initialisation, the hex records are parsed (slow) and the start address is determined as well as checksums being calculated

When you are ready to start the OAD process, you would first write the image meta information to the target, using the imgIdentifyRequestData() method. When the targets writes 0x000 to the block characteristic, its signals you to start the block transfer. You can now write blocks, using the nextBlock() method. 

Example usage is shown in the OADViewController
