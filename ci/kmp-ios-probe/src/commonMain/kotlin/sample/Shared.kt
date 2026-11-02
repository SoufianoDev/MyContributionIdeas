package sample

class SharedGreeting {
    fun greeting(): String = "Hello from a Linux-hosted KMP compilation probe"
}

fun sharedGreeting(): String = SharedGreeting().greeting()
