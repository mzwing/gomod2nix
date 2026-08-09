package main

import (
	"fmt"

	"example.com/depa"
	"example.com/locallib"
)

func main() {
	fmt.Println(depa.Hello() + " + " + locallib.Local())
}
