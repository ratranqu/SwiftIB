//
//  main.swift
//  HistoryDataDump
//
//  Created by Harry Li on 10/01/2015.
//  Copyright (c) 2014,2015 Hanfei Li. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is furnished to
// do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

import Foundation

// constants
let EXT = "history_raw"
let HEADER_LEN = 19

var conf = HDDConfig(arg_array: CommandLine.arguments)
var tickers = conf.tickers
var fman = FileManager.default
var wrapper = HistoryDataWrapper()
var client = EClientSocket(p_eWrapper: wrapper, p_anyWrapper: wrapper)

func checkGaps(filename: String, ticker: String, requestId: Int) {
    var fcontent = try! NSString(contentsOfFile: filename, encoding: String.Encoding.utf8.rawValue)
    var lns = 0
    var lastDT: Int64 = -1
    var gaps = [(String, String)]()
    var secs = HDDUtil.parseBarsize(sbarsize: conf.barsize)
    var es = 0
    fcontent.enumerateLines({ (line: String!, p: UnsafeMutablePointer<ObjCBool>) -> Void in
        let datestr = (line as NSString).substring(with: NSRange(location: 0, length: HEADER_LEN))
        if lastDT == -1 {
            lastDT = HDDUtil.fastStrToTS(timestamp: datestr)
        } else {
            if lastDT - secs != HDDUtil.fastStrToTS(timestamp: datestr) {
                gaps.append((HDDUtil.tsToStr(timestamp: lastDT, api: false), datestr))
                lastDT = HDDUtil.fastStrToTS(timestamp: datestr)
            } else {
                lastDT = lastDT - secs
            }
        }
        es += 1
    })
    if gaps.count > 0 {
        print("for \(filename)")
        for (later, earlier) in gaps {
            print("\t\tGap: \(earlier) -- \(later)")
        }
    } else {
        print("for \(filename): COMPLETE [\(es)] entries")
    }
}

func getLastestDate(filename: String) -> Int64 {
    var fcontent = try! NSString(contentsOfFile: filename, encoding: String.Encoding.utf8.rawValue)
    var count = 0
    fcontent.enumerateLines({ (line: String!, p: UnsafeMutablePointer<ObjCBool>) -> Void in
        count += 1
    })
    var ret: Int64 = -1
    fcontent.enumerateLines({ (line: String!, p: UnsafeMutablePointer<ObjCBool>) -> Void in
        count -= 1
        if count == 0 {
            
            let datestr = (line as NSString).substring(with: NSRange(location: 0, length: HEADER_LEN))
            ret = HDDUtil.fastStrToTS(timestamp: datestr)
        }
    })
    return ret
}

func downloadHistoryData(filename: String, ticker: String, requestId: Int, append: Bool = false) {
    var con = Contract(p_conId: 0, p_symbol: ticker, p_secType: "STK", p_expiry: "", p_strike: 0.0, p_right: "", p_multiplier: "",
        p_exchange: conf.exchange, p_currency: "USD", p_localSymbol: ticker, p_tradingClass: "", p_comboLegs: nil, p_primaryExch: conf.primaryEx,
        p_includeExpired: false, p_secIdType: "", p_secId: "")
    var lf: FileHandle?
    if append {
        let next = getLastestDate(filename: filename)
        if next != -1 {
            wrapper.currentStart = next
        }
        if wrapper.currentStart <= wrapper.sinceTS {
            print("\t[\(ticker)] fully downloaded. Skip.")
            return
        }
        print("\tAppending \(filename), starting date [\(HDDUtil.tsToStr(timestamp: wrapper.currentStart, api: false))]")
        lf = FileHandle(forUpdatingAtPath: filename)
        if lf != nil {
            lf?.seekToEndOfFile()
        }
    } else {
        fman.createFile(atPath: filename, contents: nil, attributes: nil)
        lf = FileHandle(forWritingAtPath: filename)
    }
    wrapper.currentTicker = ticker
    while wrapper.currentStart > wrapper.sinceTS {
        let begin = NSDate().timeIntervalSinceReferenceDate
        let localStart = wrapper.currentStart
        wrapper.currentStart = -1
        wrapper.contents.removeAll(keepingCapacity: true)
        wrapper.reqComplete = false
        wrapper.broken = false
        client.reqHistoricalData(requestId, contract: con, endDateTime: "\(HDDUtil.tsToStr(timestamp: localStart, api: true)) EST", durationStr: conf.duration, barSizeSetting: conf.barsize, whatToShow: "TRADES", useRTH: conf.rth, formatDate: 2, chartOptions: nil)
        while (wrapper.reqComplete == false) && (wrapper.broken == false) && (wrapper.extraSleep <= 0.0)
        { Thread.sleep(forTimeInterval: TimeInterval(0.05)) }
        if wrapper.broken {
            Thread.sleep(forTimeInterval: TimeInterval(2.0))
            wrapper.currentStart = localStart
            client = EClientSocket(p_eWrapper: wrapper, p_anyWrapper: wrapper)
            client.eConnect(conf.host, p_port: conf.port)
            wrapper.closing = false
            continue
        }
        if let file = lf {
            for c in wrapper.contents {
                file.write(c.data(using: String.Encoding.utf8, allowLossyConversion: true)!)
            }
            file.synchronizeFile()
        }
        print("(sleep for \(conf.sleepInterval + wrapper.extraSleep) secs)...")
        Thread.sleep(until: NSDate(timeIntervalSinceReferenceDate: begin + conf.sleepInterval + wrapper.extraSleep) as Date)
        if wrapper.extraSleep > 0 {
            wrapper.currentStart = localStart
            wrapper.extraSleep = 0
        }
    }
    if lf != nil {
        lf?.closeFile()
    }
}

conf.printConf()
print("Connecting to IB API...")
client.eConnect(conf.host, port: Int(conf.port), clientId: conf.clientID)
wrapper.closing = false

for i in 0 ..< tickers.count {
    wrapper.sinceTS = HDDUtil.strToTS(timestamp: conf.sinceDatetime, api: true)
    wrapper.currentStart = HDDUtil.strToTS(timestamp: conf.untilDatetime, api: true)
    let fn = conf.outputDir.appending("[\(tickers[i])][\(conf.exchange)-\(conf.primaryEx)][\(conf.sinceDatetime)]-[\(conf.untilDatetime)][\(conf.barsize)].\(EXT)")
    let fname = conf.normal_filename ? fn.replacingOccurrences(of: ":", with: "") : fn
    if fman.fileExists(atPath: fname) {
        if conf.append {
            downloadHistoryData(filename: fname, ticker: tickers[i], requestId: i, append: true)
            continue
        } else {
            print("Skip \(tickers[i]) : File exists")
            continue
        }
    } else {
        downloadHistoryData(filename: fname, ticker: tickers[i], requestId: i)
    }
}

Thread.sleep(forTimeInterval: TimeInterval(3.0))
wrapper.closing = true
client.eDisconnect()
client.close()

