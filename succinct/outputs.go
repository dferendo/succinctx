package succinct

import (
	"github.com/consensys/gnark/frontend"
	"github.com/succinctlabs/gnark-gadgets/vars"
)

type OutputWriter struct {
	api   frontend.API
	ptr   int
	bytes []vars.Byte
}

func NewOutputWriter(api frontend.API) *OutputWriter {
	return &OutputWriter{
		api:   api,
		ptr:   0,
		bytes: make([]vars.Byte, 0),
	}
}

func (w *OutputWriter) WriteUint64(value vars.Uint64) {
	for i := 0; i < 8; i++ {
		w.bytes = append(w.bytes, value.Bytes[i])
	}
}
