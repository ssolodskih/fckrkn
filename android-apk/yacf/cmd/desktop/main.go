// Command desktop runs the yacf relay core on a normal machine so the copied
// core can be tested against the live function without a phone. It is NOT
// shipped in the APK — the app calls yacf.Start directly.
//
// Config via env (same names as the Go client): FUNCTION_URL, TOKEN, LISTEN
// (default 127.0.0.1:1080), DEBUG=1 for per-exchange logs.
//
//	FUNCTION_URL=... TOKEN=... DEBUG=1 go run ./cmd/desktop
package main

import (
	"log"
	"os"

	"yacfapk/yacf"
)

type stderrLogger struct{}

func (stderrLogger) Log(msg string) { log.Println(msg) }

func main() {
	log.SetFlags(0)
	if err := yacf.Start(os.Getenv("FUNCTION_URL"), os.Getenv("TOKEN"), os.Getenv("LISTEN"), stderrLogger{}); err != nil {
		log.Fatalln("yacf:", err)
	}
	if os.Getenv("DEBUG") == "1" {
		yacf.SetDebug(true)
	}
	select {} // Start runs the accept loop in a goroutine; block forever
}
