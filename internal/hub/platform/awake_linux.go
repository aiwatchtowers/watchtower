package platform

// NewAwake on linux: there is no keep-awake; Hold succeeds and does nothing.
func NewAwake() Awake { return noAwake{} }

type noAwake struct{}

func (noAwake) Hold(string) (func(), error) { return func() {}, nil }
