// Package depb is a synthetic test dependency that imports depa.
package depb

import "example.com/depa"

// Greet returns depa's greeting with a suffix.
func Greet() string {
	return depa.Hello() + " via depb"
}
