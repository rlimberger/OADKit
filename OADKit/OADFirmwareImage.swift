//
//  Created by Rene Limberger on 4/13/16.
//  Copyright © 2016 Favionics. All rights reserved.
//

import Foundation

// This is a firmware image generator for the Ti BLE OAD firmware update process
// 
// This image is constructed with a string, this string is assumed a "fullflash" hex image
// that was read in by String(contentsOfURL: url), where url is the path to the fullflash kex image
// 
// This class parses the intel hex sting to find the start address of the image, and builds a single
// data blob from all bytes in all records in the hex file. 
//
// You can then use the nextBlock() function to get data for the next 16byte block during programming
//
// Notes: This currently only supports image type 1, app+stack and was only tested for off-chip OAD,
// using the "safe" method, where the first and last page of the flash remain intact.
// It was also only tested with fullflash intel hex files that are generated by using hexmerge.py from
// the intel hex python module, as per Ti's OAD user guide.
//
// This code was inspired by some of the OAD code in the Ti Android SensorTag app.

class FirmwareImage : NSObject {
    
    // image header
    var crc0: Int = 0
    var crc1: Int = 0
    var ver:  Int = 0
    var len:  Int = 0
    var addr: UInt32 = 0
    let uid = [UInt8](repeating: 0x45, count: 4)
    var imgType: ImgType = .EFL_OAD_IMG_TYPE_APP
    
    // image bin blob data
    var data = Data()
    
    // fixed assumptions made, using intel hex from hexmerge.py
    let OAD_BLOCK_SIZE = 16
    let HAL_FLASH_WORD_SIZE = 4
    
    // programming counters used duing bulk block transfer
    var iBlocks = 0 // Number of blocks programmed
    var nBlocks = 0 // Total number of blocks
    
    // source: https://en.wikipedia.org/wiki/Intel_HEX
    enum RecordType: Int {
        case DATA = 0x00, EOF, EXT_SEG_ADDR, START_SEG_ADDR, EXT_LIN_ADDR, START_LIN_ADDR
    }
    
    // image types for Ti OAD target
    enum ImgType: Int {
        case EFL_OAD_IMG_TYPE_APP = 1 // TODO: support other types
    }
    
    // initialize with a string, which is a hex file read from disc
    init(file: String) {
        super.init()
        
        // trun file string into array of lines
        let lines = generateLines(string: file)
        
        // parse lines
        parseLines(lines: lines)
        
        // update header fields (start address was updated during the parse)
        len = (data.count / (16 / 4))
        crc1 = Int(0xFFFF)
        crc0 = calcImageCRC(startPage: 0, data: data)
        
        // reset all counters
        resetProgress()
    }
    
    // TODO: initializer that takes a file path and handles the reading as well
    //init(url: NSURL)
    
    // reset counters
    func resetProgress() {
        iBlocks = 0
        nBlocks = (len / (OAD_BLOCK_SIZE / HAL_FLASH_WORD_SIZE))
    }
    
    // request the next block in the bin blob
    func nextBlock() -> Data? {
        let b = block(blockNum: iBlocks)
        iBlocks += 1
        return b
    }
    
    // request a specific block
    private func block(blockNum: Int) -> Data? {
        if blockNum < nBlocks {
            iBlocks = blockNum
            
            var block = [UInt8](repeating: 0, count: OAD_BLOCK_SIZE+2)
            
            block[0] = (UInt8(blockNum & 0xFF))
            block[1] = (UInt8((blockNum >> 8) & 0xFF))
            
            let range = Range(blockNum*OAD_BLOCK_SIZE..<blockNum*OAD_BLOCK_SIZE+OAD_BLOCK_SIZE)
            let subdata = data.subdata(in: range)
            subdata.copyBytes(to: &block[2], count: OAD_BLOCK_SIZE)
            
            return Data(bytes: block, count: block.count)
        }
        
        return nil
    }

    // turn hex string into an array of records
    private func generateLines(string: String) -> [String] {
        let newlineChars = NSCharacterSet.newlines
        return string.components(separatedBy: newlineChars).filter{!$0.isEmpty}
    }
    
    // parse all records in the hex
    // FIXME: this is very slow. explore parsing using NSScanner, etc.
    private func parseLines(lines: [String]) {
        var currentAddressBase: UInt32 = 0
        var currentAddress: UInt32?
        
        for line in lines {
            // all lines need to start with a : character
            guard line[line.startIndex] == ":" else { continue }
            
            // try to get the number of bytes in this line
            let numBytesStr = line[line.index(line.startIndex, offsetBy: 1)...line.index(line.startIndex, offsetBy: 2)]
            guard let numBytes = Int(numBytesStr, radix: 16) else { continue }
            
            // try to get record type
            let recordTypeStr = line[line.index(line.startIndex, offsetBy: 7)...line.index(line.startIndex, offsetBy: 8)]
            guard let recordTypeInt = Int(recordTypeStr, radix: 16), let recordType = RecordType(rawValue: recordTypeInt) else { continue }
            
            switch recordType {
            case .DATA:
                // try to get 16bit block address
                let blockAddrStr = line[line.index(line.startIndex, offsetBy: 3)...line.index(line.startIndex, offsetBy: 6)]
                guard var blockAddr = UInt32(blockAddrStr, radix: 16) else { continue }
                
                // the block address in the line is relative to a previous base address record (if there was one)
                blockAddr += currentAddressBase
                
                // if this is the very first data block address in the image, 
                // this will be the address we report in the image header
                // the OAD target will program the image starting at this address, after reboot
                if currentAddress == nil {
                    addr = blockAddr / (16 / 4) //block address is multiple of 4 as per OAD UG
                }
                
                // this is not the first address, check if we need to padd
                if let currentAddress = currentAddress, currentAddress < blockAddr {
                    let numPadBytes = Int(blockAddr-currentAddress)
                    let padData = [UInt8](repeating: 0xFF, count: numPadBytes)
                    data.append(Data(bytes: padData, count: padData.count))
                }
                
                currentAddress = blockAddr
                
                // try to get the bytes as Data
                let lineDataStr = line[line.index(line.startIndex, offsetBy: 9)..<line.index(line.startIndex, offsetBy: (9+(numBytes*2)))]
                guard let lineData = lineDataStr.dataFromHexString() else { continue }
                data.append(lineData as Data)
                currentAddress = currentAddress! + UInt32(lineData.count)
                
                // we only support 16 byte blocks currently
                // check that this block was 16 bytes, if not, pad 
                if lineData.count < 16 {
                    let numBytesToPad = 16-lineData.count
                    let padData = [UInt8](repeating: 0xFF, count: numBytesToPad)
                    data.append(Data(bytes: padData, count: padData.count))
                    currentAddress = currentAddress! + UInt32(padData.count)
                }
                
            case .EXT_LIN_ADDR:
                // try to get ext seg 16bit address
                let extLinAddrStr = line[line.index(line.startIndex, offsetBy: 9)..<line.index(line.startIndex, offsetBy: (9+4))]
                guard var extLinAddr = UInt32(extLinAddrStr, radix: 16) else { continue }
                extLinAddr <<= 16
                // update current base address. all subsequent addresses are relative to this base address
                currentAddressBase = extLinAddr
                
            case .EOF:
                break
                
            // TODO: handle the remaining record types. for Ti BLE OAD, those are not currently needed
            // because hexmerge.py doesn't produce lines of these record types
            //case .EXT_SEG_ADDR:
            //case .START_SEG_ADDR:
            //case .START_LIN_ADDR:
                
            default:
                // TODO: handle unknown record type
                ()
            }
        }
    }
    
    // print image header for debugging
    func printHdr() {
        print("FwUpdateActivity_CC26xx ", "ImgHdr.len = ", len)
        print("FwUpdateActivity_CC26xx ", "ImgHdr.ver = ", ver)
        print("FwUpdateActivity_CC26xx ", String(format: "ImgHdr.uid = 0x%02x%02x%02x%02x", uid[0], uid[1], uid[2], uid[3]));
        print("FwUpdateActivity_CC26xx ", "ImgHdr.addr = ", String(format: "0x%04x", UInt16(addr & 0xFFFF)))
        print("FwUpdateActivity_CC26xx ", "ImgHdr.imgType = ", imgType)
        print("FwUpdateActivity_CC26xx ", String(format: "ImgHdr.crc0 = 0x%04x", UInt16(crc0 & 0xFFFF)))
        print("FwUpdateActivity_CC26xx ", imgIdentifyRequestData().hexArrayString())
        //print(data)
    }
    
    // calculate CRC over the binary blob
    private func calcImageCRC(startPage: Int, data: Data) -> Int {
        var crc = 0
        var addr = startPage * 0x1000
        
        var page = startPage
        var pageEnd = (Int)(len / (0x1000 / 4))
        let osetEnd = ((len - (pageEnd * (0x1000 / 4))) * 4)
        
        pageEnd += startPage
        
        while (true) {
            var oset = 0
            while oset < 0x1000 {
                if ((page == startPage) && (oset == 0x00)) {
                    //Skip the CRC and shadow.
                    //Note: this increments by 3 because oset is incremented by 1 in each pass
                    //through the loop
                    oset += 3
                }
                
                else if ((page == pageEnd) && (oset == osetEnd)) {
                    crc = crc16(startCrc: crc, startVal: 0x00)
                    crc = crc16(startCrc: crc, startVal: 0x00)
        
                    oset += 1
                    return crc
                }
                    
                else {
                    data.withUnsafeBytes {(bytes: UnsafePointer<UInt8>) in
                        crc = crc16(startCrc: crc, startVal: Int(bytes[Int(addr + oset)]))
                    }
                }
            }
        
            page += 1
            addr = page * 0x1000
            oset += 1
        }
    }
    
    // calculate a 16bit crc
    private func crc16(startCrc: Int, startVal: Int) -> Int {
        var val = startVal
        var crc = startCrc
        let poly = 0x1021
        var cnt = 0;
        
        while cnt < 8 {
            var msb = 0
            
            if ((crc & 0x8000) == 0x8000) {
                msb = 1
            }
            
            else {
                msb = 0
            }
            
            crc <<= 1
            if ((val & 0x80) == 0x80) {
                crc |= 0x0001
            }
            
            if (msb == 1) {
                crc ^= poly
            }
            
            cnt += 1
            val <<= 1
        }
        
        return crc;
    }
    
    // generate the image header data to identify with the OAD target
    func imgIdentifyRequestData() -> Data {
        let tmp = [
            UInt8(crc0 & 0xFF),
            UInt8((crc0 >> 8) & 0xFF),
            UInt8(crc1 & 0xFF),
            UInt8((crc1 >> 8) & 0xFF),
            UInt8(ver & 0xFF),
            UInt8((ver >> 8) & 0xFF),
            UInt8(len & 0xFF),
            UInt8((len >> 8) & 0xFF),
            uid[0],
            uid[1],
            uid[2],
            uid[3],
            UInt8(addr & 0xFF),
            UInt8((addr >> 8) & 0xFF),
            UInt8(imgType.rawValue & 0xFF),
            UInt8(0xFF)]
        
        return Data(bytes: tmp, count: tmp.count)
    }
}

// source: http://stackoverflow.com/questions/26501276/converting-hex-string-to-nsdata-in-swift
extension Data {
    func hexArrayString() -> String {
        var str = "["
        var bytes = [UInt8](repeating: 0, count: count)
        copyBytes(to: &bytes, count: count)
        for b in bytes {
            str += String(format: "0x%02x, ", b)
        }
        str += "]"
        return str
    }
}

// source: http://stackoverflow.com/questions/26501276/converting-hex-string-to-nsdata-in-swift
extension String {
    func dataFromHexString() -> Data? {
        var hex = self.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).replacingOccurrences(of: " ", with: "")
        
        var data = Data()
        while(hex.characters.count > 0) {
            let c: String = hex.substring(to: hex.index(hex.startIndex, offsetBy: 2))
            hex = hex.substring(from: hex.index(hex.startIndex, offsetBy: 2))
            var ch: UInt32 = 0
            Scanner(string: c).scanHexInt32(&ch)
            var char = UInt8(ch)
            data.append(&char, count: 1)
        }
        return data
    }
}
