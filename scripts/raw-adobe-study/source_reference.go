package main
import("context";"fmt";"os";"time";"open-make-tiff/internal/convert";"open-make-tiff/internal/config")
func main(){
 c:=convert.New()
 cfg:=&config.Config{KeepIntermediateFiles:true,KeepLogFiles:true}
 for _,path:=range os.Args[1:]{
  t:=time.Now(); if err:=c.Convert(context.Background(),path,cfg);err!=nil{panic(err)}
  fmt.Println(path,time.Since(t))
 }
}
