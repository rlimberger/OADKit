//
//  Created by Rene Limberger on 3/30/16.
//  Copyright © 2016 Favionics. All rights reserved.
//

import UIKit
import CoreBluetooth

class OADViewController: UITableViewController {
    
    // uuid of the OAD target peripheral
    var uuid: String?
    
    // identifier of the subdirectory when we look for the FW image
    var product: String?
    
    // current version of the target
    var currentVersion: String?
    
    // product container
    var productObject: Product?
    
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
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if let prod = product {
            productObject = OADManager.sharedManager.products[prod]
            title = prod + " Firmware update"
        }
        
        UIApplication.sharedApplication().cancelAllLocalNotifications()
        UIApplication.sharedApplication().applicationIconBadgeNumber = -1
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(didWriteValueForCharacteristic(_:)), name: "didWriteValueForCharacteristic", object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(didUpdateValueForCharacteristic(_:)), name: "didUpdateValueForCharacteristic", object: nil)
    }
    
    override func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        
        if let prod = productObject where prod.sortedVersions.count > 1 {
            return 2
        }
        
        return 1
    }
    
    override func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return 1
        } else {
            return (productObject?.sortedVersions.count ?? 1) - 1
        }
    }
    
    override func tableView(tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 {
            return "Latest version"
        } else {
            return "Previous versions"
        }
    }
    
    override func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        guard let prod = productObject, cell = tableView.dequeueReusableCellWithIdentifier("VersionCell") else { return UITableViewCell() }
        
        var version: FirmwareVersion?
        if indexPath.section == 0 {
            version = prod.sortedVersions.first
        } else {
            version = prod.sortedVersions[indexPath.row+1]
        }
        
        if let version = version {
            cell.textLabel?.text = version.version
            
            let formatter = NSDateFormatter()
            formatter.dateStyle = .MediumStyle
            formatter.timeStyle = .NoStyle
            cell.detailTextLabel?.text = formatter.stringFromDate(version.date)
            
            if let currentVersion = currentVersion where version.version == currentVersion {
                cell.accessoryType = . Checkmark
            } else {
                cell.accessoryType = .DisclosureIndicator
            }
        }
        
        return cell
    }
    
    @IBAction func done() {
        // NOTE: because the update process is modal (UIAlertController)
        //       the done button is blocked until the process is finished or cancelled.
        dismissViewControllerAnimated(true, completion: nil)
    }
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }
    
    override func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        tableView.deselectRowAtIndexPath(indexPath, animated: true)
        
        if let productObject = productObject where indexPath.row < productObject.sortedVersions.count {
            showUpdateConfirmAlert(productObject.sortedVersions[indexPath.row])
        }
    }
    
    func showUpdateConfirmAlert(version: FirmwareVersion) {
        
        let title = "Start firmware update to version \(version.version)?"
        let message = "This may take a few minutes."
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .Alert)
        
        alert.addAction(UIAlertAction(title: "Update", style: .Destructive, handler: {[weak self] (action) in
            self?.updateFirmware(BTCentral.sharedCentral.peripherals[self?.uuid ?? " "], version: version)
        }))
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .Cancel, handler: nil)
        alert.addAction(cancelAction)
        alert.preferredAction = cancelAction
        
        presentViewController(alert, animated: true, completion: nil)
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
        guard let _ = startDate, img = img, uuid = uuid, peripheral = BTCentral.sharedCentral.peripherals[uuid], identifyChar = BTCentral.sharedCentral.characteristicsLookupTable[peripheral.identifier.UUIDString]?[fxOADImgBlockUUID.UUIDString] else {
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
        
        dispatch_async(dispatch_get_main_queue()) {[weak self] in
            let alert = UIAlertController(title: "Firmware update failed!", message: message, preferredStyle: .Alert)
            alert.addAction(UIAlertAction(title: "Ok", style: .Default, handler: nil))
            self?.progressAlert?.dismissViewControllerAnimated(true, completion: nil)
            self?.presentViewController(alert, animated: true, completion: nil)
        }
    }
    
    func showProgrammingDoneDialog() {
        blockTransferTimer?.invalidate()
        
        dispatch_async(dispatch_get_main_queue()) {[weak self] in
            let alert = UIAlertController(title: "Firmware update complete!", message: "The device will turn off now. When you turn it back on, it will perform the firmware update post process.", preferredStyle: .Alert)
        
            alert.addAction(UIAlertAction(title: "Ok", style: .Cancel, handler: nil))
        
            self?.progressAlert?.dismissViewControllerAnimated(true, completion: nil)
            self?.presentViewController(alert, animated: true, completion: nil)
        }
    }
    
    func showProgressDialog() {
        progressAlert?.dismissViewControllerAnimated(true, completion: nil)
        let alert = UIAlertController(title: "Updating firmware", message: "Getting new firmware from iCloud...", preferredStyle: .Alert)
        
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
        if let peripheral = peripheral, identifyChar = BTCentral.sharedCentral.characteristicsLookupTable[peripheral.identifier.UUIDString]?[fxOADImgIdentifyUUID.UUIDString], data = img?.imgIdentifyRequestData() {
            peripheral.writeValue(data, forCharacteristic: identifyChar, type: CBCharacteristicWriteType.WithResponse)
            updateProgressStats()
        }
    }
    
    func endProgramming() {
        progressAlert?.dismissViewControllerAnimated(true, completion: nil)
        progressAlert = nil
        resetProgrammingStack()
    }
    
    func resetProgrammingStack() {
        startDate = nil
        blockTransferTimer?.invalidate()
        img?.resetProgress()
    }
    
    func updateFirmware(peripheral: CBPeripheral?, version: FirmwareVersion) {
        showProgressDialog()
        
        OADManager.sharedManager.fetchFirmwareImageAsync(version) {[weak self] (image) in
            if self?.progressAlert != nil {
                dispatch_async(dispatch_get_main_queue()) {[weak self] in
                    self?.progressAlert?.message = "Starting Bluetooth upload..."
                }
                self?.img = image
                self?.startProgramming(peripheral)
            }
        }
    }

}

