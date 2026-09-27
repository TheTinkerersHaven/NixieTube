package nixietube.innertube

import kotlinx.coroutines.runBlocking

// Temporary Phase-0 spike validation. Run with:
// ./gradlew :core:innertube:smoke
/**
 * Manual smoke probe: prints home shelves, a search hit, its stream and an album detail.
 *
 * @param args unused command-line arguments.
 */
fun main(args: Array<String>) {
    runBlocking {
    val tube = InnerTube()
    val home = tube.home()
    println("HOME shelves: ${home.size}")
    home.take(3).forEach { println("  - ${it.title} (${it.items.size} items)") }

    val results = tube.search("daft punk")
    println("SEARCH sections: ${results.keys}")
    val firstSong = results.values.flatten().filterIsInstance<ShelfItem.Song>().firstOrNull()?.track
    println("First song: ${firstSong?.title} by ${firstSong?.artistNames} [${firstSong?.videoId}]")
    if (firstSong != null) {
        val stream = StreamResolver.resolve(firstSong.videoId)
        println("Stream: bitrate=${stream?.bitrate} codec=${stream?.codec} urlLen=${stream?.url?.length}")
    }

    val album = results.values.flatten().filterIsInstance<ShelfItem.Browse>()
        .firstOrNull { it.browseId.startsWith("MPRE") }
    println("First album result: ${album?.title}")
    if (album != null) {
        val detail = tube.album(album.browseId)
        println("Album detail: ${detail?.title} tracks=${detail?.tracks?.size}")
    }

    }
}
