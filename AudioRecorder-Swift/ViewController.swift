//
//  ViewController.swift
//  AudioRecorder-Swift
//
//  Created by Sean on 2018/6/4.
//  Copyright © 2018年 swift. All rights reserved.
//

import UIKit

class ViewController: UIViewController {

    lazy var recorder: AudioRecorder = {
        let path = CommonUtil.documentsPath("recorder.caf")
        return AudioRecorder(path)
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
    }
    
    @IBAction func record(_ sender: Any) {
        recorder.start()
    }
    
    @IBAction func stop(_ sender: Any) {
        recorder.stop()
    }
}

