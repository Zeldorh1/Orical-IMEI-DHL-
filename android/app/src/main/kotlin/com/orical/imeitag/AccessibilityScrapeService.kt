package com.orical.imeitag

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Reads visible text from the system Settings app (restricted via
 * accessibility_service_config.xml's android:packageNames="com.android.settings")
 * and picks out IMEI / EID / Serial values into a thread-safe singleton that
 * the MethodChannel handler in MainActivity reads on demand.
 *
 * The service does NOT click, scroll, or take any action; it only collects
 * displayed text nodes whose value matches the expected patterns.
 */
class AccessibilityScrapeService : AccessibilityService() {

    companion object {
        @Volatile var imei: String? = null
        @Volatile var imei2: String? = null
        @Volatile var eid: String? = null
        @Volatile var meid: String? = null
        @Volatile var serial: String? = null
        @Volatile var model: String? = null
        @Volatile var lastUpdatedMs: Long = 0L

        @Volatile var enabledScrape: Boolean = false

        fun reset() {
            imei = null
            imei2 = null
            eid = null
            meid = null
            serial = null
            model = null
            lastUpdatedMs = 0L
        }

        private val imeiRegex = Regex("\\b\\d{15}\\b")
        private val eidRegex = Regex("\\b\\d{30,32}\\b")
        private val meidRegex = Regex("\\b[0-9A-Fa-f]{14}\\b")

        fun luhn15(s: String): Boolean {
            if (s.length != 15 || !s.all { it.isDigit() }) return false
            var sum = 0
            for (i in 0 until 15) {
                var d = s[14 - i].digitToInt()
                if (i % 2 == 1) {
                    d *= 2
                    if (d > 9) d -= 9
                }
                sum += d
            }
            return sum % 10 == 0
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (!enabledScrape) return
        val root = rootInActiveWindow ?: return
        try {
            val packageName = event?.packageName?.toString() ?: ""
            if (!packageName.startsWith("com.android.settings") &&
                !packageName.contains("settings", ignoreCase = true)) {
                return
            }

            val collected = mutableListOf<String>()
            walk(root, collected)
            val joined = collected.joinToString("\n")

            val foundImeis = imeiRegex.findAll(joined)
                .map { it.value }
                .filter { luhn15(it) }
                .toList()
                .distinct()

            if (foundImeis.isNotEmpty()) {
                imei = foundImeis[0]
                if (foundImeis.size > 1) imei2 = foundImeis[1]
                lastUpdatedMs = System.currentTimeMillis()
            }

            eidRegex.findAll(joined).firstOrNull()?.let {
                eid = it.value
                lastUpdatedMs = System.currentTimeMillis()
            }

            collected.forEachIndexed { i, line ->
                val lower = line.lowercase()
                if (lower.contains("serial") && i + 1 < collected.size) {
                    val next = collected[i + 1].trim()
                    if (next.isNotEmpty() && next.length in 6..30 && !next.contains(' ')) {
                        serial = next
                        lastUpdatedMs = System.currentTimeMillis()
                    }
                }
                if (lower == "model" && i + 1 < collected.size) {
                    model = collected[i + 1].trim()
                    lastUpdatedMs = System.currentTimeMillis()
                }
            }
        } catch (_: Throwable) {
            // Defensive: never crash from a scrape.
        }
    }

    private fun walk(node: AccessibilityNodeInfo?, out: MutableList<String>) {
        if (node == null) return
        node.text?.toString()?.takeIf { it.isNotEmpty() }?.let { out.add(it) }
        node.contentDescription?.toString()?.takeIf { it.isNotEmpty() }?.let { out.add(it) }
        for (i in 0 until node.childCount) {
            walk(node.getChild(i), out)
        }
    }

    override fun onInterrupt() {}

    override fun onServiceConnected() {
        super.onServiceConnected()
    }
}
