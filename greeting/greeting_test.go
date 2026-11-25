package greeting

import "testing"

func TestGreetingReturnsExactString(t *testing.T) {
	want := "Hello from the Go starter!"
	if got := Greeting(); got != want {
		t.Fatalf("Greeting() returned %q. Want %q.", got, want)
	}
}
