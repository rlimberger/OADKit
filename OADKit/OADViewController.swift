//
//  Created by Rene Limberger on 3/30/16.
//  Copyright © 2016 Favionics. All rights reserved.
//

import UIKit
import CoreBluetooth

class OADViewController: UIViewController {
    
    // uuid of the OAD target peripheral
    var uuid: String?
    
    // identifier of the subdirectory when we look for the FW image
    var product: String?
    
    // current version of the target
    var currentVersion: String?
    
    // the firmware image to work with
    var img: FirmwareImage?
    
    // progress
    var startDate: NSDate?
    var blockTransferTimer: NSTimer?
    var progressView: UIProgressView?
    var progressAlert: UIAlertController?
    
    @IBOutlet weak var doneButton: UIBarButtonItem!
    @IBOutlet weak var updateButton: UIBarButtonItem!
    
    // BLE bulk tranfer parameters
    //
    // Note: our FW images are typically ~200k for a CC2640, this includes app & stack
    //       these transfer in ~60sec which gives ~3kb/sec
    //
    let NUM_BLOCK_PER_CONNECTION = 4    // send 4, 16 byte blocks
    let BLOCK_TRANSFER_INTERVAL  = 0.03 // every 30ms
    
    @IBOutlet weak var textView: UITextView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(didWriteValueForCharacteristic(_:)), name: "didWriteValueForCharacteristic", object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(didUpdateValueForCharacteristic(_:)), name: "didUpdateValueForCharacteristic", object: nil)
    }
    
    @IBAction func done() {
        // NOTE: because the update process is modal (UIAlertController)
        //       the done button is blocked until the process is finished or cancelled.
        dismissViewControllerAnimated(true, completion: nil)
    }
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }
    
    @IBAction func update() {
        showUpdateConfirmAlert()
    }
    
    func showUpdateConfirmAlert() {
        
        let title = "Are you sure you want to start the firmware update?"
        let message = "Make sure your battery is fully charged and do not disconnect the battery during this process!"
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .Alert)
        
        alert.addAction(UIAlertAction(title: "Update", style: .Destructive, handler: {[weak self] (action) in
            self?.updateFirmware(BTCentral.sharedCentral.peripherals[self?.uuid ?? " "])
        }))
        
        alert.addAction(UIAlertAction(title: "Remind me later", style: .Default, handler: {(action) in
                // TODO: reminder
        }))
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .Cancel, handler: nil))
        
        presentViewController(alert, animated: true, completion: nil)
    }
    
    class func firmwareURL(product: String) -> NSURL? {
        if let resourceURL = NSBundle.mainBundle().resourceURL {
            let firmwareURL = resourceURL.URLByAppendingPathComponent("firmware")
            let productURL = firmwareURL.URLByAppendingPathComponent(product)
            
            return productURL
        }
        
        return nil
    }
    
    class func versionInfoDictForProduct(product: String) -> Dictionary<String, AnyObject>? {
        if let productURL = firmwareURL(product) {
            let versionPlistURL = productURL.URLByAppendingPathComponent("version.plist")
            
            return NSDictionary(contentsOfURL: versionPlistURL) as? Dictionary<String, AnyObject>
        }
        
        return nil
    }
    
    class func newFirmwareVersion(product: String?, currentVersion: String) -> String? {
        if let product = product, versionInfoDict = versionInfoDictForProduct(product), version = versionInfoDict["version"] as? String {
            if version.compare(currentVersion, options: .NumericSearch, range: nil, locale: nil) == .OrderedDescending {
                return version
            }
        }
        
        return nil
    }
    
    class func firmwareImage(product: String?) -> FirmwareImage? {
        if let product = product, url = OADViewController.firmwareURL(product)?.URLByAppendingPathComponent("fw.hex") {
            do {
                let fwString = try String(contentsOfURL: url)
                return FirmwareImage(file: fwString)
            } catch _ {
                
            }
        }
        
        return nil
    }
    
    func didWriteValueForCharacteristic(notification: NSNotification) {
        guard let characteristic = notification.object as? CBCharacteristic, value = characteristic.value else {return}
        
        switch characteristic.UUID {
        case fxOADImgIdentifyUUID, fxOADImgBlockUUID:
            print("didWriteValueForCharacteristic", value)
            
        default:
            ()
        }
    }
    
    func programmingTick(timer: NSTimer) {
        guard let _ = startDate, img = img, uuid = uuid, peripheral = BTCentral.sharedCentral.peripherals[uuid], identifyChar = BTCentral.sharedCentral.characteristicsLookupTable[fxOADImgBlockUUID.UUIDString] else {
            timer.invalidate()
            showProgrammingErrorDialog("Something went wrong during block transfer setup.")
            return
        }
        
        for _ in 0..<NUM_BLOCK_PER_CONNECTION {
            if let blockData = img.nextBlock() {
                peripheral.writeValue(blockData, forCharacteristic: identifyChar, type: CBCharacteristicWriteType.WithoutResponse)
                //print("sent block", img.iBlocks, blockData.hexArrayString())
            } else {
                
                // can't get any more blocks
                timer.invalidate()
                
                // TODO: should timeout if target doesn't confirm image after some time
                
                if img.iBlocks >= img.nBlocks {
                    showProgrammingDoneDialog()
                } else {
                    showProgrammingErrorDialog("Unable to get next block from firmware image.")
                }
                
                return
            }
        }
        
        updateProgressStats()
    }
    
    func startBlockTransferTimer() {
        img?.resetProgress()
        
        blockTransferTimer = NSTimer.schedule(repeatInterval: BLOCK_TRANSFER_INTERVAL) {[weak self] (timer) in
            self?.programmingTick(timer)
        }
    }
    
    func didUpdateValueForCharacteristic(notification: NSNotification) {
        guard let characteristic = notification.object as? CBCharacteristic, value = characteristic.value else {return}
        
        switch characteristic.UUID {
        case fxOADImgIdentifyUUID:
            // if target writes 8b to the identify char, it means it rejected the image header
            blockTransferTimer?.invalidate()
            showProgrammingErrorDialog("Invalid firmware image.")
            
        case fxOADImgBlockUUID:
            print(value)
            if value.length == 2 {
                var block: UInt16 = 0xFFFF
                value.getBytes(&block, length: 2)
                
                switch block {
                case 0:
                    startBlockTransferTimer()
                    
                case 0xFFFF:
                    // block rejected
                    blockTransferTimer?.invalidate()
                    showProgrammingErrorDialog("Block error")
                    print("Error")
                    
                default:
                    // any other block request is dropped silently
                    ()
                }
            }
            
        default:
            ()
        }
    }
    
    
    func updateProgressStats() {
        if let startDate = startDate, img = img {
            let seconds = NSDate().timeIntervalSinceDate(startDate)
            let progress = Float(img.iBlocks) / Float(img.nBlocks)
            
            var estimatedTotalTimeStr = "..."
            
            if progress > 0 {
                let estimateSeconds = Double(1.0/progress) * seconds
                estimatedTotalTimeStr = String(format: "%dsec", Int(estimateSeconds))
            }
            
            dispatch_async(dispatch_get_main_queue()) {[weak self] in
                self?.progressView?.progress = progress
                self?.progressAlert?.message = String(format: "%d of ", Int(seconds)) + estimatedTotalTimeStr
            }
        }
    }
    
    func showProgrammingErrorDialog(message: String? = nil) {
        blockTransferTimer?.invalidate()
        
        let alert = UIAlertController(title: "Firmware update failed!", message: message, preferredStyle: .Alert)
        alert.addAction(UIAlertAction(title: "Ok", style: .Default, handler: nil))
        
        dispatch_async(dispatch_get_main_queue()) {[weak self] in
            self?.progressAlert?.dismissViewControllerAnimated(true, completion: nil)
            self?.presentViewController(alert, animated: true, completion: nil)
        }
    }
    
    func showProgrammingDoneDialog() {
        blockTransferTimer?.invalidate()
        
        let alert = UIAlertController(title: "Firmware update complete!", message: "The device will turn off now. When you turn it back on, it will perform the firmware update post process.", preferredStyle: .Alert)
        
        alert.addAction(UIAlertAction(title: "Ok", style: .Cancel, handler: nil))
        
        dispatch_async(dispatch_get_main_queue()) {[weak self] in
            self?.progressAlert?.dismissViewControllerAnimated(true, completion: nil)
            self?.presentViewController(alert, animated: true, completion: nil)
        }
    }
    
    func showProgressDialog() {
        progressAlert?.dismissViewControllerAnimated(true, completion: nil)
        let alert = UIAlertController(title: "Updating firmware", message: " ", preferredStyle: .Alert)
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .Cancel) {[weak self] (action) in
            self?.endProgramming()
        })
        
        self.progressAlert = alert
        
        presentViewController(alert, animated: true) {[weak self] in
            let margin:CGFloat = 8.0
            let rect = CGRectMake(margin, 70.0, alert.view.frame.width - margin * 2.0 , 4.0)
            let progressView = UIProgressView(frame: rect)
            progressView.progress = 0.0
            self?.progressAlert?.view.addSubview(progressView)
            self?.progressView = progressView
        }
    }
    
    func startProgramming(peripheral: CBPeripheral?) {
        img?.printHdr()
        resetProgrammingStack()
        startDate = NSDate()
        
        // write image header to ident char to kick start the OAD process
        if let peripheral = peripheral, identifyChar = BTCentral.sharedCentral.characteristicsLookupTable[fxOADImgIdentifyUUID.UUIDString], data = img?.imgIdentifyRequestData() {
            peripheral.writeValue(data, forCharacteristic: identifyChar, type: CBCharacteristicWriteType.WithResponse)
            updateProgressStats()
        }
    }
    
    func endProgramming() {
        resetProgrammingStack()
    }
    
    func resetProgrammingStack() {
        startDate = nil
        blockTransferTimer?.invalidate()
        img?.resetProgress()
    }
    
    func updateFirmware(peripheral: CBPeripheral?) {
        showProgressDialog()
        
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0)) {[weak self] in
            self?.img = OADViewController.firmwareImage(self?.product)
            self?.startProgramming(peripheral)
        }
    }

}

