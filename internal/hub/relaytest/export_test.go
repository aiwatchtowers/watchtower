package relaytest

// EventsQueuedFor is, per WebSocket device ever opened (oldest first), the
// event frames queued on it, and the frames parked for its next socket.
func (s *Server) EventsQueuedFor(device string) (perSocket []int, parked int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.all {
		if c.device == device {
			perSocket = append(perSocket, c.queued)
		}
	}
	return perSocket, len(s.pending[device])
}
