package main

import (
	"bufio"
	"io"
	"net/http"
)

// flushBytes is how many buffered bytes accumulate before the response is pushed
// to the client. A large DMA takes minutes to enumerate, so without periodic
// flushing the caller sees nothing at all until the buffer happens to fill, and a
// working request is indistinguishable from a stalled one. One megabyte keeps
// syscall overhead negligible while still producing visible progress within a
// second or so.
const flushBytes = 1 << 20

// bufferBytes is the buffered writer size. Address lines are about 14 bytes, so
// this batches roughly eighteen thousand of them per underlying write.
const bufferBytes = 256 << 10

// flushWriter buffers output and periodically flushes it through to the client.
//
// It wraps whatever the response body is, which may be a gzip writer rather than
// the ResponseWriter itself, while flushing the ResponseWriter separately. Those
// are two distinct operations: flushing the buffer moves bytes into gzip, and
// flushing the ResponseWriter moves gzip output onto the socket. Doing only the
// first leaves data sitting in the HTTP layer.
type flushWriter struct {
	bw         *bufio.Writer
	flusher    http.Flusher
	sinceFlush int
}

func newFlushWriter(dst io.Writer, rw http.ResponseWriter) *flushWriter {
	f, _ := rw.(http.Flusher)
	return &flushWriter{
		bw:      bufio.NewWriterSize(dst, bufferBytes),
		flusher: f,
	}
}

func (f *flushWriter) maybeFlush() error {
	if f.sinceFlush < flushBytes {
		return nil
	}
	if err := f.bw.Flush(); err != nil {
		return err
	}
	if f.flusher != nil {
		f.flusher.Flush()
	}
	f.sinceFlush = 0
	return nil
}

func (f *flushWriter) Write(p []byte) (int, error) {
	n, err := f.bw.Write(p)
	f.sinceFlush += n
	if err != nil {
		return n, err
	}
	return n, f.maybeFlush()
}

func (f *flushWriter) WriteString(s string) (int, error) {
	n, err := f.bw.WriteString(s)
	f.sinceFlush += n
	if err != nil {
		return n, err
	}
	return n, f.maybeFlush()
}

func (f *flushWriter) WriteByte(b byte) error {
	if err := f.bw.WriteByte(b); err != nil {
		return err
	}
	f.sinceFlush++
	return f.maybeFlush()
}

// Flush empties the buffer and pushes it to the client. Called once at the end of
// a response, after which the gzip writer if any must still be closed.
func (f *flushWriter) Flush() error {
	if err := f.bw.Flush(); err != nil {
		return err
	}
	if f.flusher != nil {
		f.flusher.Flush()
	}
	f.sinceFlush = 0
	return nil
}
