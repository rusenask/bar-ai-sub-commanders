package game

import (
	"context"
	"io"
)

// Conn is one link to the game widget: JSON messages, one per line, both ways.
type Conn interface {
	io.ReadWriteCloser
	// Describe says where the link comes from, for logs.
	Describe() string
}

// Listener hands out the game widget's links as they come: a TCP connection, or a file session where
// BAR takes sockets away from widgets (transport_tcp.go, transport_files.go). A new link replaces the
// current one, like a reconnect.
type Listener interface {
	// Accept blocks until the next link or until ctx is done.
	Accept(ctx context.Context) (Conn, error)
	Close() error
	// Addr says where it listens, for logs.
	Addr() string
}

// Serve accepts links from l until ctx is done; each new one becomes the game's connection.
func (s *Server) Serve(ctx context.Context, l Listener) error {
	context.AfterFunc(ctx, func() { l.Close() })
	s.log.Info("waiting for the game", "on", l.Addr())
	for {
		c, err := l.Accept(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		s.attach(c)
	}
}
