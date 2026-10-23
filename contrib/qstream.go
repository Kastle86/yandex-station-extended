package main

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ──────────────────────────────────────────────────────────────────────────
// Очередь как ОДИН непрерывный mp3: /music/q/<qid>.mp3 = треки очереди подряд.
// Колонка не умеет сама просить следующий трек (callbacks/stack engine в audio_play
// она не дёргает), а один длинный поток играет до конца без участия сервера.
// Каждому треку — слот фиксированной длины (dur+1)*24000 байт (CBR 192k), хвост
// слота добиваем тишиной. Поэтому позиция колонки (offset_ms в device_state)
// однозначно даёт номер трека: «что играет», «дальше», «назад», продолжение.
// ──────────────────────────────────────────────────────────────────────────

type qStream struct {
	ID    string   `json:"id"`
	Songs []ndSong `json:"songs"`
}

func slotBytes(s ndSong) int64 { return int64(s.Duration+1) * mp3BytesPerSec }

// startMs — начало трека i в потоке (мс).
func (q *qStream) startMs(i int) int {
	ms := 0
	for _, s := range q.Songs[:i] {
		ms += (s.Duration + 1) * 1000
	}
	return ms
}

// trackAt — номер трека по позиции в потоке (мс).
func (q *qStream) trackAt(ms int) int {
	acc := 0
	for i, s := range q.Songs {
		acc += (s.Duration + 1) * 1000
		if ms < acc {
			return i
		}
	}
	return len(q.Songs) - 1
}

func (q *qStream) url() string {
	return fmt.Sprintf("%s/music/q/%s.mp3", envOr("MUSIC_PUBLIC", "http://192.168.1.190:18080"), q.ID)
}

var qStreams = struct {
	sync.Mutex
	m map[string]*qStream
}{m: map[string]*qStream{}}

func queueDir() string { return filepath.Join(musicCacheDir(), "queues") }

// newQStream регистрирует очередь (с длительностями) и сохраняет её на диск,
// чтобы ссылка переживала перезапуск сервера.
func newQStream(songs []ndSong) (*qStream, error) {
	songs = withDurations(songs)
	if len(songs) == 0 {
		return nil, fmt.Errorf("пустая очередь")
	}
	h := sha1.New()
	for _, s := range songs {
		h.Write([]byte(s.ID + ","))
	}
	q := &qStream{ID: hex.EncodeToString(h.Sum(nil))[:12], Songs: songs}
	qStreams.Lock()
	qStreams.m[q.ID] = q
	qStreams.Unlock()
	os.MkdirAll(queueDir(), 0o755)
	b, _ := json.Marshal(q)
	return q, os.WriteFile(filepath.Join(queueDir(), q.ID+".json"), b, 0o644)
}

func getQStream(id string) *qStream {
	qStreams.Lock()
	defer qStreams.Unlock()
	if q, ok := qStreams.m[id]; ok {
		return q
	}
	b, err := os.ReadFile(filepath.Join(queueDir(), id+".json"))
	if err != nil {
		return nil
	}
	var q qStream
	if json.Unmarshal(b, &q) != nil || len(q.Songs) == 0 {
		return nil
	}
	qStreams.m[id] = &q
	return &q
}

// withDurations дотягивает длительности (AudioMuse отдаёт треки без них) и
// выкидывает то, что Navidrome не знает.
func withDurations(songs []ndSong) []ndSong {
	out := make([]ndSong, len(songs))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for i, s := range songs {
		if s.Duration > 0 || s.Src != "" {
			out[i] = s
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			if full, err := ndSongByID(s.ID); err == nil {
				out[i] = full
			}
		}()
	}
	wg.Wait()
	kept := out[:0]
	for _, s := range out {
		if s.ID != "" && s.Duration > 0 {
			kept = append(kept, s)
		}
	}
	return kept
}

// silenceMP3 — секунда тишины в тех же параметрах (44.1k, 192k CBR, без Xing/ID3):
// ей добиваем хвост слота, чтобы между треками не было мусора.
var silenceMP3 = sync.OnceValue(func() []byte {
	out, err := exec.Command("ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi",
		"-i", "anullsrc=r=44100:cl=stereo", "-t", "1", "-c:a", "libmp3lame", "-b:a", "192k",
		"-write_xing", "0", "-id3v2_version", "0", "-f", "mp3", "-").Output()
	if err != nil || len(out) == 0 {
		log.Printf("MUSIC silence: %v — добиваю нулями", err)
		return make([]byte, 4096)
	}
	return out
})

// serveQ отдаёт /music/q/<qid>.mp3 с Range: склейка слотов очереди.
func serveQ(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/music/q/"), ".mp3")
	q := getQStream(id)
	if q == nil {
		http.NotFound(w, r)
		return
	}
	var total int64
	starts := make([]int64, len(q.Songs))
	for i, s := range q.Songs {
		starts[i] = total
		total += slotBytes(s)
	}
	start, end, status, ok := parseRange(w, r, total)
	if !ok {
		return
	}
	w.Header().Set("Content-Type", "audio/mpeg")
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
	w.WriteHeader(status)
	if r.Method == http.MethodHead {
		return
	}
	pos := start
	for pos <= end {
		i := len(starts) - 1
		for j := range starts {
			if j+1 == len(starts) || pos < starts[j+1] {
				i = j
				break
			}
		}
		if i+1 < len(q.Songs) {
			songMP3(q.Songs[i+1]) // следующий перекодируется, пока играет этот
		}
		slotEnd := starts[i] + slotBytes(q.Songs[i]) - 1
		to := min(end, slotEnd)
		if err := songMP3(q.Songs[i]).copyRange(w, pos-starts[i], to-starts[i]); err != nil {
			log.Printf("MUSIC q/%s [%d] %s: %v", id, i+1, q.Songs[i].name(), err)
			return
		}
		pos = to + 1
	}
}

// parseRange разбирает Range для «файла» длины total и ставит Content-Range.
func parseRange(w http.ResponseWriter, r *http.Request, total int64) (start, end int64, status int, ok bool) {
	start, end, status = 0, total-1, http.StatusOK
	rg := r.Header.Get("Range")
	if !strings.HasPrefix(rg, "bytes=") {
		return start, end, status, true
	}
	a, b, _ := strings.Cut(strings.TrimPrefix(rg, "bytes="), "-")
	if v, err := strconv.ParseInt(a, 10, 64); err == nil {
		start = v
	}
	if v, err := strconv.ParseInt(b, 10, 64); err == nil && v < end {
		end = v
	}
	if start > end {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", total))
		http.Error(w, "range", http.StatusRequestedRangeNotSatisfiable)
		return 0, 0, 0, false
	}
	w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, total))
	return start, end, http.StatusPartialContent, true
}

// copyRange пишет байты [from, to] трека (пока ffmpeg пишет — ждёт; после конца
// реального файла — тишина до конца слота).
func (t *mp3Track) copyRange(w http.ResponseWriter, from, to int64) error {
	sil := silenceMP3()
	buf := make([]byte, 64<<10)
	pos := from
	for pos <= to {
		t.mu.Lock()
		for !t.done && t.size <= pos {
			t.cond.Wait()
		}
		path, size, done, terr := t.path, t.size, t.done, t.err
		t.mu.Unlock()
		if terr != nil {
			return fmt.Errorf("transcode: %w", terr)
		}
		want := to - pos + 1
		if pos < size {
			f, err := os.Open(path)
			if err != nil { // .part переименовали в .mp3 — следующий круг откроет новый
				time.Sleep(5 * time.Millisecond)
				continue
			}
			n, _ := f.ReadAt(buf[:min(int64(len(buf)), want, size-pos)], pos)
			f.Close()
			if n == 0 {
				continue
			}
			if _, err := w.Write(buf[:n]); err != nil {
				return err
			}
			pos += int64(n)
		} else if done {
			off := int((pos - size) % int64(len(sil)))
			n := min(int64(len(sil)-off), want)
			if _, err := w.Write(sil[off : off+int(n)]); err != nil {
				return err
			}
			pos += n
		}
	}
	return nil
}
