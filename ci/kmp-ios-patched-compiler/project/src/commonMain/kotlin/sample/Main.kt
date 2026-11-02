package sample

class ProbeGreeting {
    fun message(): String = "Kotlin/Native iOS ARM64 codegen from a Linux host"
}

fun main() {
    println(ProbeGreeting().message())
}
