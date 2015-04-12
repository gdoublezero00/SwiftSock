//
//  SwiftSock.swift
//  SwiftSock
//
//  Created by Jun Izumida on 11/5/14.
//  Copyright (c) 2014 jp.co.agel. All rights reserved.
//

import Foundation

public protocol SwiftSockDelegate {
    func socketSuccess(info:Dictionary<String, String>!) -> Void
    func socketError(info:Dictionary<String, String>!, error:NSError!) -> Void
    func socketTimeout(info:Dictionary<String, String>!) -> Void
}

public class SwiftSock: NSObject, NSStreamDelegate {
    public var delegate:SwiftSockDelegate!
    
    private let BUFFER_SIZE = 1024
    private var inputStream:NSInputStream!
    private var outputStream:NSOutputStream!
    private var timeoutTimer:NSTimer!
    private var tag:String!
    private var server:String!
    private var port:UInt32!
    private var message:String!
    private var sendString:String!
    private var retry:Int!
    private var statusDictionary:Dictionary<String, String>!
    private var statusError:NSError! = nil
    private var mutableBuffer:NSMutableData! = nil
    
    //
    // MARK: Main Connection
    //
    public func connectionStart(server: String, port: Int, requestMessage: String, retryCount: Int) -> Void {
        self.server = server
        self.port = UInt32(port)
        self.message = requestMessage
        self.retry = retryCount
        self.statusDictionary = Dictionary()
        self.connect()
    }
    
    public func connectionStart(server: String, port: Int, requestMessage: String) -> Void {
        self.server = server
        self.port = UInt32(port)
        self.message = requestMessage
        self.retry = 0
        self.statusDictionary = Dictionary()
        self.connect()
    }
    
    public func connectionStartWithTag(tag: String, server: String, port: Int, requestMessage: String, retryCount: Int) -> Void {
        self.tag = tag
        self.server = server
        self.port = UInt32(port)
        self.message = requestMessage
        self.retry = retryCount
        self.statusDictionary = Dictionary()
        self.connect()
    }
    
    //
    // MARK: Call from Internal
    //
    func connect() -> Void {
        var readStream:Unmanaged<CFReadStream>?
        var writeStream:Unmanaged<CFWriteStream>?
        self.message = self.message + "EOF"
        self.sendString = self.message
        
        CFStreamCreatePairWithSocketToHost(
            nil,
            self.server as NSString as CFStringRef,
            self.port,
            &readStream,
            &writeStream
        )
        self.inputStream = readStream!.takeRetainedValue()
        self.outputStream = writeStream!.takeRetainedValue()
        self.inputStream.delegate = self;
        self.outputStream.delegate = self;
        self.inputStream.scheduleInRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)
        self.outputStream.scheduleInRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)
        self.inputStream.open()
        self.outputStream.open()
        self.startConnectionTimer()
    }
    func connectionClose() -> Void {
        self.inputStream.close()
        self.outputStream.close()
        self.inputStream.removeFromRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)
        self.outputStream.removeFromRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)
    }
    
    //
    // MARK: Delegate
    //
    func handlerSocketSuccess() -> Void {
        self.connectionClose()
        return delegate.socketSuccess(self.statusDictionary)
    }
    func handlerSocketError() -> Void {
        self.connectionClose()
        if self.retry == 0 {
            return delegate.socketError(self.statusDictionary, error:self.statusError)
        } else {
            self.retry = self.retry - 1
            let delay = 3.0 * Double(NSEC_PER_SEC)
            let time = dispatch_time(DISPATCH_TIME_NOW, Int64(delay))
            dispatch_after(time, dispatch_get_main_queue(), {
                self.connect()
            })
        }
    }
    func handlerSocketTimeout() -> Void {
        self.connectionClose()
        return delegate.socketTimeout(self.statusDictionary)
    }
    
    //
    // MARK: NSStreamDelegate
    //
    public func stream(aStream: NSStream, handleEvent eventCode: NSStreamEvent) {
        self.stopConnectionTimer()
        switch eventCode {
        case NSStreamEvent.OpenCompleted:
            // Connection Open
            break
        case NSStreamEvent.EndEncountered:
            // Connection End
            if aStream == self.inputStream {
                self.handlerSocketSuccess()
            }
            break
        case NSStreamEvent.ErrorOccurred:
            // Connection Error
            let err:NSError = aStream.streamError!
            self.statusDictionary["Tag"] = self.tag
            self.statusDictionary["Message"] = ""
            self.statusDictionary["StatusCode"] = "-1"
            self.statusDictionary["StatusMessage"] = err.localizedDescription
            self.handlerSocketError()
            break
        case NSStreamEvent.HasSpaceAvailable:
            // Send Message
            if aStream == self.outputStream {
                if (self.message.lengthOfBytesUsingEncoding(NSUTF8StringEncoding) > 0) {
                    var sendString = self.message
                    while sendString.lengthOfBytesUsingEncoding(NSUTF8StringEncoding) > 0 {
                        let limitLength = sendString.lengthOfBytesUsingEncoding(NSUTF8StringEncoding) > BUFFER_SIZE ? BUFFER_SIZE : sendString.lengthOfBytesUsingEncoding(NSUTF8StringEncoding)
                        let str = sendString.substringToIndex(advance(sendString.startIndex, limitLength))
                        println(str)
                        let buf = str.cStringUsingEncoding(NSASCIIStringEncoding)!
                        let len:UInt = UInt(strlen(buf))
                        self.outputStream.write(UnsafePointer<UInt8>(buf), maxLength: Int(len))
                        sendString = sendString.substringFromIndex(advance(sendString.startIndex, limitLength))
                    }
                    self.message = ""
                    self.mutableBuffer = NSMutableData()
                }
            }
            break
        case NSStreamEvent.HasBytesAvailable:
            if aStream == self.inputStream {
                var buf = [UInt8](count: BUFFER_SIZE, repeatedValue: 0)
                while self.inputStream.hasBytesAvailable {
                    var len = self.inputStream.read(&buf, maxLength: BUFFER_SIZE)
                    if len > 0 {
                        mutableBuffer.appendBytes(buf, length: len)
                    }
                }
                self.statusDictionary["Tag"] = self.tag
                self.statusDictionary["Message"] = NSString(bytes: mutableBuffer.bytes, length: mutableBuffer.length, encoding: NSShiftJISStringEncoding)! as String
                self.statusDictionary["StatusCode"] = "0"
                self.statusDictionary["StatusMessage"] = "OK"
            }
            break
        default:
            break
        }
    }
    
    //
    // MARK: Timeout
    //
    func startConnectionTimer() -> Void {
        self.stopConnectionTimer()
        let interval:NSTimeInterval = 3.0
        self.timeoutTimer = NSTimer.scheduledTimerWithTimeInterval(interval, target: self, selector: "timeoutConnectionTimer", userInfo: nil, repeats: false)
    }
    func stopConnectionTimer() -> Void {
        if self.timeoutTimer != nil {
            self.timeoutTimer.invalidate()
            self.timeoutTimer = nil
        }
    }
    func timeoutConnectionTimer() -> Void {
        self.stopConnectionTimer()
        self.connectionClose()
        // Call delegate
        self.statusDictionary["Tag"] = self.tag
        self.statusDictionary["Message"] = ""
        self.statusDictionary["StatusCode"] = "-2"
        self.statusDictionary["StatusMessage"] = "TimeOut"
        self.handlerSocketTimeout()
    }
}
