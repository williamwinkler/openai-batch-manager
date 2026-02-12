// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/batcher"
import topbar from "../vendor/topbar"

// JSON Syntax Highlighting hook
const JsonSyntaxHighlight = {
  mounted() {
    this.highlight()
  },
  updated() {
    this.highlight()
  },
  highlight() {
    const content = this.el.textContent
    if (!content) return

    // Apply syntax highlighting
    const highlighted = this.syntaxHighlight(content)
    this.el.innerHTML = highlighted
  },
  syntaxHighlight(json) {
    // Escape HTML entities first
    const escaped = json
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')

    // Apply syntax highlighting with regex
    return escaped.replace(
      /("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+\-]?\d+)?)/g,
      (match) => {
        let cls = 'json-number' // number
        if (/^"/.test(match)) {
          if (/:$/.test(match)) {
            cls = 'json-key' // key
          } else {
            cls = 'json-string' // string
          }
        } else if (/true|false/.test(match)) {
          cls = 'json-boolean' // boolean
        } else if (/null/.test(match)) {
          cls = 'json-null' // null
        }
        return '<span class="' + cls + '">' + match + '</span>'
      }
    )
  }
}

// Clickable table row hook
const ClickableRow = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      // Don't navigate if clicking on interactive elements
      const interactive = e.target.closest("a, button, input, select, textarea, [phx-click]")
      if (interactive && interactive !== this.el) {
        return
      }

      const path = this.el.dataset.navigatePath
      if (path) {
        // Use LiveView's native link handling by creating a temporary link
        const link = document.createElement("a")
        link.href = path
        link.setAttribute("data-phx-link", "patch")
        link.setAttribute("data-phx-link-state", "push")
        document.body.appendChild(link)
        link.click()
        link.remove()
      }
    })
  }
}

// Theme toggle hook
const ThemeToggle = {
  mounted() {
    this.updateActiveButton()
    // Listen for theme changes
    window.addEventListener("phx:set-theme", () => {
      setTimeout(() => this.updateActiveButton(), 10)
    })
    // Listen for storage changes (e.g., from another tab)
    window.addEventListener("storage", (e) => {
      if (e.key === "phx:theme") {
        setTimeout(() => this.updateActiveButton(), 10)
      }
    })
  },

  updated() {
    this.updateActiveButton()
  },

  updateActiveButton() {
    const buttons = this.el.querySelectorAll(".theme-btn")
    const hasDataTheme = document.documentElement.hasAttribute("data-theme")
    const storedTheme = localStorage.getItem("phx:theme")
    const currentTheme = hasDataTheme ? document.documentElement.getAttribute("data-theme") :
                        (storedTheme || "system")

    buttons.forEach(btn => {
      const themeValue = btn.dataset.themeValue
      const isSystem = !hasDataTheme && !storedTheme
      const isActive = (themeValue === "system" && isSystem) ||
                      (themeValue !== "system" && themeValue === currentTheme)

      if (isActive) {
        btn.classList.add("bg-primary", "text-primary-content")
        btn.classList.remove("hover:bg-base-200")
        const icon = btn.querySelector("span")
        if (icon) {
          icon.classList.remove("text-base-content/60")
          icon.classList.add("text-primary-content")
        }
      } else {
        btn.classList.remove("bg-primary", "text-primary-content")
        btn.classList.add("hover:bg-base-200")
        const icon = btn.querySelector("span")
        if (icon) {
          icon.classList.add("text-base-content/60")
          icon.classList.remove("text-primary-content")
        }
      }
    })
  }
}

// Fixed-position tooltip hook (escapes overflow containers)
const Tooltip = {
  mounted() {
    this.tooltip = null
    this.el.addEventListener("mouseenter", () => this.show())
    this.el.addEventListener("mouseleave", () => this.hide())
  },
  destroyed() {
    this.hide()
  },
  show() {
    const text = this.el.dataset.tip
    if (!text) return

    this.tooltip = document.createElement("div")
    this.tooltip.textContent = text
    this.tooltip.className = "fixed z-[9999] px-2 py-1 text-xs rounded bg-neutral text-neutral-content max-w-xs pointer-events-none"
    document.body.appendChild(this.tooltip)

    const rect = this.el.getBoundingClientRect()
    const tipRect = this.tooltip.getBoundingClientRect()
    let left = rect.left + (rect.width - tipRect.width) / 2
    let top = rect.bottom + 6

    // Keep tooltip within viewport
    if (left < 4) left = 4
    if (left + tipRect.width > window.innerWidth - 4) left = window.innerWidth - tipRect.width - 4
    if (top + tipRect.height > window.innerHeight - 4) top = rect.top - tipRect.height - 6

    this.tooltip.style.left = left + "px"
    this.tooltip.style.top = top + "px"
  },
  hide() {
    if (this.tooltip) {
      this.tooltip.remove()
      this.tooltip = null
    }
  }
}

// Local time conversion hook - converts UTC timestamps to browser local time
const LocalTime = {
  mounted() {
    this.startAutoRefresh()
    this.formatTime()
  },
  updated() { this.formatTime() },
  destroyed() { this.stopAutoRefresh() },
  disconnected() { this.stopAutoRefresh() },
  reconnected() {
    this.startAutoRefresh()
    this.formatTime()
  },
  startAutoRefresh() {
    this.stopAutoRefresh()
    if (this.el.dataset.format === "time-ago-tooltip") {
      this.refreshTimer = setInterval(() => this.formatTime(), 30_000)
    }
  },
  stopAutoRefresh() {
    if (this.refreshTimer) {
      clearInterval(this.refreshTimer)
      this.refreshTimer = null
    }
  },
  formatRelativeTime(date) {
    const diffSeconds = Math.floor((Date.now() - date.getTime()) / 1000)

    if (diffSeconds < 0) return "in the future"
    if (diffSeconds < 60) return "<1m ago"
    if (diffSeconds < 3600) return `${Math.floor(diffSeconds / 60)}m ago`
    if (diffSeconds < 86_400) return `${Math.floor(diffSeconds / 3600)}h ago`
    if (diffSeconds < 604_800) return `${Math.floor(diffSeconds / 86_400)}d ago`
    if (diffSeconds < 2_592_000) return `${Math.floor(diffSeconds / 604_800)}w ago`
    if (diffSeconds < 31_536_000) return `${Math.floor(diffSeconds / 2_592_000)}mo ago`
    return `${Math.floor(diffSeconds / 31_536_000)}y ago`
  },
  formatTime() {
    const utc = this.el.dataset.utc
    if (!utc) return

    const date = new Date(utc.endsWith('Z') ? utc : utc + 'Z')
    if (isNaN(date.getTime())) return

    const format = this.el.dataset.format || "datetime"
    const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    const day = String(date.getDate()).padStart(2, '0')
    const month = months[date.getMonth()]
    const monthNum = String(date.getMonth() + 1).padStart(2, '0')
    const year = date.getFullYear()
    const hours = String(date.getHours()).padStart(2, '0')
    const minutes = String(date.getMinutes()).padStart(2, '0')
    const seconds = String(date.getSeconds()).padStart(2, '0')

    let formatted
    switch (format) {
      case "datetime":
        formatted = `${day} ${month} ${year}, ${hours}:${minutes}`
        break
      case "datetime-short":
        formatted = `${day} ${month} ${hours}:${minutes}`
        break
      case "time":
        formatted = `${hours}:${minutes}:${seconds}`
        break
      case "tooltip":
        formatted = `${day}/${monthNum}/${year}, ${hours}:${minutes}`
        break
      case "time-ago-tooltip":
        this.el.title = `${day}/${monthNum}/${year}, ${hours}:${minutes}`
        this.el.textContent = this.formatRelativeTime(date)
        return
      default:
        return
    }

    if (format === "tooltip") {
      this.el.title = formatted
    } else {
      this.el.textContent = formatted
    }
  }
}

// RabbitMQ Modal hook
const RabbitMQModal = {
  mounted() {
    const modalId = this.el.dataset.modalId
    const modal = document.getElementById(modalId)
    
    if (!modal) return

    // Open modal on button click
    this.el.addEventListener("click", () => {
      modal.classList.remove("hidden")
      document.body.style.overflow = "hidden"
    })

    // Close modal on backdrop or close button click
    const closeHandlers = modal.querySelectorAll("[data-close-modal]")
    closeHandlers.forEach(handler => {
      handler.addEventListener("click", () => {
        modal.classList.add("hidden")
        document.body.style.overflow = ""
      })
    })
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    ClickableRow,
    ThemeToggle,
    JsonSyntaxHighlight,
    LocalTime,
    RabbitMQModal,
    Tooltip
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
