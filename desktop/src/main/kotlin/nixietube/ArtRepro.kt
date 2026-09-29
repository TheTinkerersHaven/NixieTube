package nixietube

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import java.net.URI
import javax.imageio.ImageIO

// Temporary isolated repro: 480x360 bitmap in a 200dp box with Crop on RED.
/**
 * Temporary isolated repro entry point: renders a 480x360 remote bitmap in a 200dp crop box.
 *
 * Used to verify artwork scaling/cropping behavior outside the main app window.
 */
fun main() = application {
    val bytes = URI("https://i.ytimg.com/vi/khnokW3Mw24/hqdefault.jpg").toURL().readBytes()
    val img = ImageIO.read(bytes.inputStream())
    println("REPRO BITMAP: ${img.width}x${img.height} type=${img.type}")
    val bmp = img.toComposeImageBitmap()
    println("REPRO COMPOSE: ${bmp.width}x${bmp.height}")
    Window(onCloseRequest = ::exitApplication, title = "artrepro") {
        MaterialTheme(colorScheme = darkColorScheme()) {
            Box(Modifier.background(Color.Red)) {
                Image(
                    bmp,
                    null,
                    Modifier.size(200.dp).clip(RoundedCornerShape(12.dp)),
                    contentScale = ContentScale.Crop,
                )
            }
        }
    }
}
