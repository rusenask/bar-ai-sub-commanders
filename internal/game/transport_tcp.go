package game

import (
	"context"
	"fmt"
	"net"
)

// TCPListener accepts the widget's TCP connections (BAR up to game version test-31578).
type TCPListener struct{ ln net.Listener }

// ListenTCP listens on addr ("127.0.0.1:7878").
func ListenTCP(ctx context.Context, addr string) (*TCPListener, error) {
	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("listen %s: %w", addr, err)
	}
	return &TCPListener{ln: ln}, nil
}

func (l *TCPListener) Accept(ctx context.Context) (Conn, error) {
	c, err := l.ln.Accept()
	if err != nil {
		return nil, err
	}
	return tcpConn{c}, nil
}

func (l *TCPListener) Close() error { return l.ln.Close() }
func (l *TCPListener) Addr() string { return "tcp " + l.ln.Addr().String() }

type tcpConn struct{ net.Conn }

func (c tcpConn) Describe() string { return "tcp " + c.RemoteAddr().String() }
