package nixietube.player

// Engine interface. UI and queue logic program against this;
// swapping backends (GStreamer, Qt later) means a new impl only.
/** Backend-agnostic playback contract for audio engines (mpv, future backends). */
interface PlayerEngine {
    /**
     * Starts playback of the stream at [url], replacing any current media.
     *
     * @param url Direct audio/video stream URL to load.
     * @return True if playback started successfully.
     */
    fun play(url: String): Boolean
    /** Pauses playback, retaining the current position. */
    fun pause()
    /** Resumes playback after [pause]. */
    fun resume()
    /** Stops playback and unloads the current media. */
    fun stop()
    /**
     * Seeks to an absolute position.
     *
     * @param ms Target position in milliseconds from the start.
     */
    fun seekTo(ms: Long)
    /**
     * Sets the output volume.
     *
     * @param volume0to100 Volume level from 0 (muted) to 100 (full).
     */
    fun setVolume(volume0to100: Int)
    /**
     * Returns the current playback position.
     *
     * @return Position in milliseconds, or 0 when nothing is loaded.
     */
    fun positionMs(): Long
    /**
     * Returns the current media duration.
     *
     * @return Duration in milliseconds, or 0 when unknown.
     */
    fun durationMs(): Long
    /**
     * Reports whether audio is currently playing.
     *
     * @return True while audible playback is in progress.
     */
    fun isPlaying(): Boolean
    /** Releases native resources held by the engine. */
    fun release()

    /** Playback lifecycle callbacks delivered by the engine. */
    interface Listener {
        /** Called when the current media finishes naturally. */
        fun onFinished()
        /**
         * Called when playback fails.
         *
         * @param message Human-readable error description.
         */
        fun onError(message: String)
    }

    /**
     * Registers a playback [listener].
     *
     * @param listener Listener to notify of finish/error events.
     */
    fun addListener(listener: Listener)
}
