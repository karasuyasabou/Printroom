import Foundation
import CryptoKit
import PrintroomCore
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let out=root.appendingPathComponent("scratch/raw-adobe-study")
let profile=try Data(contentsOf:URL(fileURLWithPath:"/Users/bao/Desktop/open_make_tiff/pkg/icc/ProPhoto.icm"))
func bytes(_ a:[UInt16])->Data { a.withUnsafeBytes {Data($0)} }
var records:[[String:Any]]=[]
for n in 7119...7126 {
 let name=String(format:"DSC%05d",n)
 try autoreleasepool {
  let src=out.appendingPathComponent("reference/\(name).ARW.tiff")
  let start=Date()
  let full=try TIFFCodec.read(url:src)
  let expected=try Data(contentsOf:out.appendingPathComponent("\(name)/direct_rgb.rgb16"))
  guard bytes(full.samples)==expected else {fatalError("source reference mismatch \(name)")}
  let preview=try TIFFCodec.readPreview(url:src,maxDimension:1600)
  let proxy=out.appendingPathComponent("\(name)/proxy.tiff")
  try TIFFCodec.write(url:proxy,width:preview.width,height:preview.height,profile:profile,compression:.deflate) {rows in
   Array(preview.samples[rows.lowerBound*preview.width*3..<rows.upperBound*preview.width*3])
  }
  let reread=try TIFFCodec.read(url:proxy)
  guard preview.samples==reread.samples else {fatalError("proxy mismatch")}
  let rect=PixelRect(x:1000,y:1000,width:11,height:11)
  let region=try TIFFCodec.readRegion(url:src,rect:rect)
  var expectedRegion:[UInt16]=[]
  for y in rect.y..<rect.y+rect.height { expectedRegion += full.samples[(y*full.width+rect.x)*3..<(y*full.width+rect.x+rect.width)*3] }
  guard region.samples==expectedRegion else {fatalError("ROI mismatch")}
  records.append(["frame":name,"width":full.width,"height":full.height,"fullSampleSHA256":SHA256.hash(data:expected).map{String(format:"%02x",$0)}.joined(),"source_reference_exact":true,"proxyWidth":preview.width,"proxyHeight":preview.height,"proxy_roundtrip_exact":true,"roi_exact":true,"seconds":Date().timeIntervalSince(start)])
  print(name,"reference/proxy/ROI PASS")
 }
}
try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("printroom-io.json"))
