// ClaudeGuard v0.1 — macOS Claude 出网管控（PoC 产品化试验）
// UI: egui/eframe. 执行层: 特权守护脚本 helper/guardd.sh (pf).
// 语义: 自动模式下「通路不健康 → 封禁(武装)；通路健康 → 放行」；也可强制封禁/放行。

use eframe::egui;
use std::collections::VecDeque;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

const STATE_DIR: &str = "/tmp/claudeguard";
const CONTROL: &str = "/tmp/claudeguard/control";
const STATUS: &str = "/tmp/claudeguard/status";
const PIDFILE: &str = "/tmp/claudeguard/daemon.pid";
const INSTALLER: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/helper/install-daemon.sh");
const UNINSTALLER: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/helper/uninstall-daemon.sh");

const DEFAULT_DOMAINS: &str =
    "claude.ai\nclaude.com\nclau.de\nanthropic.com\nclaudeusercontent.com";

#[derive(PartialEq, Clone, Copy, Debug)]
enum Mode {
    Auto,
    ForceBlock,
    ForceAllow,
}

struct Config {
    mode: Mode,
    domains: String,
    proxy_port: String,
}

struct Shared {
    probe_ok: Option<bool>,
    probe_ms: Option<u128>,
    ips4: Vec<String>,
    ips6: Vec<String>,
    last_resolve: Option<SystemTime>,
    self_test: Option<String>,
    log: VecDeque<String>,
    daemon: bool,
    status_raw: String,
    refresh_req: bool,
}

fn now_hms() -> String {
    let out = Command::new("date").arg("+%H:%M:%S").output();
    match out {
        Ok(o) => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        Err(_) => String::from("--:--:--"),
    }
}

fn push_log(shared: &Arc<Mutex<Shared>>, msg: impl Into<String>) {
    if let Ok(mut s) = shared.lock() {
        s.log.push_back(format!("[{}] {}", now_hms(), msg.into()));
        while s.log.len() > 300 {
            s.log.pop_front();
        }
    }
}

fn load_cjk_font(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    if let Ok(data) = std::fs::read("/System/Library/Fonts/Supplemental/Arial Unicode.ttf") {
        fonts
            .font_data
            .insert("cjk".to_owned(), egui::FontData::from_owned(data).into());
        if let Some(fam) = fonts.families.get_mut(&egui::FontFamily::Proportional) {
            fam.insert(0, "cjk".to_owned());
        }
        if let Some(fam) = fonts.families.get_mut(&egui::FontFamily::Monospace) {
            fam.push("cjk".to_owned());
        }
        ctx.set_fonts(fonts);
    }
}

fn sh(cmd: &str, args: &[&str]) -> String {
    match Command::new(cmd).args(args).output() {
        Ok(o) => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        Err(_) => String::new(),
    }
}

fn daemon_running() -> bool {
    let pid = std::fs::read_to_string(PIDFILE).unwrap_or_default().trim().to_string();
    if pid.is_empty() {
        return false;
    }
    Command::new("ps")
        .args(["-p", &pid])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn run_admin(shell_cmd: &str) -> Result<String, String> {
    let escaped = shell_cmd.replace('\\', "\\\\").replace('"', "\\\"");
    let script = format!(
        "do shell script \"{}\" with administrator privileges",
        escaped
    );
    match Command::new("osascript").arg("-e").arg(script).output() {
        Ok(o) => {
            if o.status.success() {
                Ok(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                Err(String::from_utf8_lossy(&o.stderr).trim().to_string())
            }
        }
        Err(e) => Err(e.to_string()),
    }
}

fn probe_path(port: &str) -> (bool, Option<u128>) {
    let proxy = format!("http://127.0.0.1:{}", port);
    let t0 = std::time::Instant::now();
    let out = Command::new("curl")
        .args([
            "-x",
            &proxy,
            "-m",
            "6",
            "-s",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "https://www.gstatic.com/generate_204",
        ])
        .output();
    let ms = t0.elapsed().as_millis();
    match out {
        Ok(o) => {
            let code = String::from_utf8_lossy(&o.stdout).trim().to_string();
            (code == "204" || code == "200", Some(ms))
        }
        Err(_) => (false, Some(ms)),
    }
}

fn resolve_domains(domains: &str, log: &Arc<Mutex<Shared>>) -> (Vec<String>, Vec<String>) {
    let mut v4 = std::collections::BTreeSet::new();
    let mut v6 = std::collections::BTreeSet::new();
    for d in domains.lines() {
        let d = d.trim();
        if d.is_empty() {
            continue;
        }
        let a = sh("dig", &["+short", "@223.5.5.5", d, "A"]);
        for ip in a.lines() {
            let ip = ip.trim();
            if ip.contains('.') && !ip.contains(':') {
                v4.insert(ip.to_string());
            }
        }
        let aaaa = sh("dig", &["+short", "@223.5.5.5", d, "AAAA"]);
        for ip in aaaa.lines() {
            let ip = ip.trim();
            if ip.contains(':') && !ip.is_empty() {
                v6.insert(ip.to_string());
            }
        }
    }
    let v4: Vec<String> = v4.into_iter().collect();
    let v6: Vec<String> = v6.into_iter().collect();
    push_log(
        log,
        format!("域名解析完成: v4={} v6={}", v4.len(), v6.len()),
    );
    (v4, v6)
}

fn write_control(mode: &str, ips4: &[String], ips6: &[String], domains: &str, upstream: &str) {
    let _ = std::fs::create_dir_all(STATE_DIR);
    let doms = domains
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let content = format!(
        "mode={}\nips4={}\nips6={}\ndomains={}\nupstream={}\n",
        mode,
        ips4.join(" "),
        ips6.join(" "),
        doms,
        upstream
    );
    let _ = std::fs::write(CONTROL, content);
}

struct App {
    cfg: Arc<Mutex<Config>>,
    shared: Arc<Mutex<Shared>>,
    port_buf: String,
    domains_buf: String,
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        load_cjk_font(&cc.egui_ctx);
        let cfg = Arc::new(Mutex::new(Config {
            mode: Mode::Auto,
            domains: DEFAULT_DOMAINS.to_string(),
            proxy_port: "7890".to_string(),
        }));
        let shared = Arc::new(Mutex::new(Shared {
            probe_ok: None,
            probe_ms: None,
            ips4: vec![],
            ips6: vec![],
            last_resolve: None,
            self_test: None,
            log: VecDeque::new(),
            daemon: false,
            status_raw: String::new(),
            refresh_req: true,
        }));

        // probe loop
        {
            let cfg = cfg.clone();
            let shared = shared.clone();
            std::thread::spawn(move || loop {
                let port = cfg.lock().map(|c| c.proxy_port.clone()).unwrap_or_default();
                let (ok, ms) = probe_path(&port);
                let daemon = daemon_running();
                let status = std::fs::read_to_string(STATUS).unwrap_or_default();
                if let Ok(mut s) = shared.lock() {
                    if s.probe_ok != Some(ok) {
                        let label = if ok { "健康" } else { "不健康" };
                        s.log.push_back(format!("[{}] 通路探测: {}", now_hms(), label));
                    }
                    s.probe_ok = Some(ok);
                    s.probe_ms = ms;
                    s.daemon = daemon;
                    s.status_raw = status.trim().to_string();
                }
                std::thread::sleep(Duration::from_secs(3));
            });
        }

        // resolve loop
        {
            let cfg = cfg.clone();
            let shared = shared.clone();
            std::thread::spawn(move || loop {
                let domains = cfg.lock().map(|c| c.domains.clone()).unwrap_or_default();
                let (v4, v6) = resolve_domains(&domains, &shared);
                if let Ok(mut s) = shared.lock() {
                    s.ips4 = v4;
                    s.ips6 = v6;
                    s.last_resolve = Some(SystemTime::now());
                }
                // wait 60s or until refresh requested
                for _ in 0..60 {
                    std::thread::sleep(Duration::from_secs(1));
                    let req = shared.lock().map(|mut s| {
                        let r = s.refresh_req;
                        s.refresh_req = false;
                        r
                    });
                    if let Ok(true) = req {
                        break;
                    }
                }
            });
        }

        // commander loop: write control file based on mode/probe
        {
            let cfg = cfg.clone();
            let shared = shared.clone();
            std::thread::spawn(move || loop {
                let (mode, domains, port) = cfg
                    .lock()
                    .map(|c| (c.mode, c.domains.clone(), c.proxy_port.clone()))
                    .unwrap_or((Mode::Auto, String::new(), "7890".to_string()));
                let (probe, ips4, ips6) = shared
                    .lock()
                    .map(|s| (s.probe_ok, s.ips4.clone(), s.ips6.clone()))
                    .unwrap_or((None, vec![], vec![]));
                let armed = match mode {
                    Mode::ForceBlock => true,
                    Mode::ForceAllow => false,
                    Mode::Auto => probe != Some(true), // fail-closed
                };
                let armed_s = if armed { "armed" } else { "disarmed" };
                let upstream = if probe == Some(true) { port.as_str() } else { "none" };
                write_control(armed_s, &ips4, &ips6, &domains, upstream);
                std::thread::sleep(Duration::from_secs(1));
            });
        }

        push_log(&shared, "ClaudeGuard 已启动（GUI 就绪）");
        Self {
            cfg,
            shared,
            port_buf: "7890".to_string(),
            domains_buf: DEFAULT_DOMAINS.to_string(),
        }
    }

    fn do_start_daemon(&mut self) {
        let script = format!("'{}'", INSTALLER);
        match run_admin(&script) {
            Ok(out) => {
                push_log(&self.shared, format!("守护启动: {}", out));
                self.port_buf = self.cfg.lock().map(|c| c.proxy_port.clone()).unwrap_or_default();
            }
            Err(e) => push_log(&self.shared, format!("守护启动失败: {}", e)),
        }
    }

    fn do_stop_daemon(&mut self) {
        let script = format!("'{}'", UNINSTALLER);
        match run_admin(&script) {
            Ok(out) => push_log(&self.shared, format!("守护停止: {}", out)),
            Err(e) => push_log(&self.shared, format!("守护停止失败: {}", e)),
        }
    }

    fn do_self_test(&mut self) {
        let port = self.port_buf.clone();
        let shared = self.shared.clone();
        push_log(&shared, "开始自测（直连 + 经代理，各一次）…");
        std::thread::spawn(move || {
            let direct = Command::new("curl")
                .args([
                    "--noproxy",
                    "*",
                    "-m",
                    "8",
                    "-s",
                    "-o",
                    "/dev/null",
                    "-w",
                    "%{http_code} in %{time_total}s",
                    "https://claude.ai",
                ])
                .output();
            let control = Command::new("curl")
                .args([
                    "--noproxy",
                    "*",
                    "-m",
                    "8",
                    "-s",
                    "-o",
                    "/dev/null",
                    "-w",
                    "%{http_code} in %{time_total}s",
                    "https://example.org",
                ])
                .output();
            let via_proxy = Command::new("curl")
                .args([
                    "-x",
                    &format!("http://127.0.0.1:{}", port),
                    "-m",
                    "8",
                    "-s",
                    "-o",
                    "/dev/null",
                    "-w",
                    "%{http_code} in %{time_total}s",
                    "https://claude.ai",
                ])
                .output();
            let d = direct
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_else(|_| "执行失败".into());
            let p = via_proxy
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_else(|_| "执行失败".into());
            let c = control
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_else(|_| "执行失败".into());
            let via_engine = Command::new("curl")
                .args([
                    "-x",
                    "http://127.0.0.1:7893",
                    "-m",
                    "5",
                    "-s",
                    "-o",
                    "/dev/null",
                    "-w",
                    "%{http_code} in %{time_total}s",
                    "https://claude.ai",
                ])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_else(|_| "执行失败".into());
            let text = format!(
                "直连 claude.ai:       {}\n经 Clash(7890):       {}\n经 ClaudeGuard(7893): {}\n对照 example.org 直连: {}",
                d, p, via_engine, c
            );
            if let Ok(mut s) = shared.lock() {
                s.self_test = Some(text.clone());
            }
            push_log(&shared, format!("自测结果 → 直连:{} / 代理:{}", d, p));
        });
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        ctx.request_repaint_after(Duration::from_secs(1));

        let (probe_ok, probe_ms, daemon, ips4, ips6, last_resolve, status_raw, self_test, log) = {
            let s = self.shared.lock().unwrap();
            (
                s.probe_ok,
                s.probe_ms,
                s.daemon,
                s.ips4.clone(),
                s.ips6.clone(),
                s.last_resolve,
                s.status_raw.clone(),
                s.self_test.clone(),
                s.log.clone(),
            )
        };

        // 同步 UI 编辑值到共享配置
        if let Ok(mut c) = self.cfg.lock() {
            c.proxy_port = self.port_buf.clone();
            c.domains = self.domains_buf.clone();
        }
        let mode = self.cfg.lock().map(|c| c.mode).unwrap_or(Mode::Auto);

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("ClaudeGuard · Claude 出网管控");
            ui.label(
                egui::RichText::new("v0.2 — 系统代理接管 + pf 直连封堵 · 自动/强制封禁 · 零 hosts 改动")
                    .weak()
                    .small(),
            );
            ui.separator();

            let mode_now0 = self.cfg.lock().map(|c| c.mode).unwrap_or(Mode::Auto);
            let intended: bool = match mode_now0 {
                Mode::ForceBlock => true,
                Mode::ForceAllow => false,
                Mode::Auto => probe_ok != Some(true),
            };
            let effective = daemon && status_raw.contains("state=armed");

            egui::Grid::new("status_grid")
                .num_columns(2)
                .spacing([18.0, 6.0])
                .show(ui, |ui| {
                    ui.label("通路（Clash 代理）:");
                    match probe_ok {
                        Some(true) => ui.colored_label(
                            egui::Color32::from_rgb(46, 160, 67),
                            format!("健康 {}ms", probe_ms.unwrap_or(0)),
                        ),
                        Some(false) => ui.colored_label(
                            egui::Color32::from_rgb(220, 80, 80),
                            "不健康 / 未开",
                        ),
                        None => ui.colored_label(egui::Color32::GRAY, "探测中…"),
                    };
                    ui.end_row();

                    ui.label("特权守护:");
                    if daemon {
                        ui.colored_label(egui::Color32::from_rgb(46, 160, 67), "运行中");
                    } else {
                        ui.colored_label(egui::Color32::GRAY, "未运行（点下方启动，需一次管理员授权）");
                    }
                    ui.end_row();

                    ui.label("策略意图:");
                    if intended {
                        ui.colored_label(egui::Color32::from_rgb(220, 80, 80), "封禁");
                    } else {
                        ui.colored_label(egui::Color32::from_rgb(46, 160, 67), "放行");
                    }
                    ui.end_row();

                    ui.label("实际生效:");
                    if effective {
                        ui.colored_label(egui::Color32::from_rgb(46, 160, 67), "已生效（pf 已装载）");
                    } else if intended {
                        ui.colored_label(egui::Color32::ORANGE, "未生效（守护未运行或未武装）");
                    } else {
                        ui.colored_label(egui::Color32::GRAY, "无封禁（放行）");
                    }
                    ui.end_row();

                    ui.label("封禁目标:");
                    ui.label(format!("IPv4 {} 条 / IPv6 {} 条", ips4.len(), ips6.len()));
                    ui.end_row();

                    ui.label("上次解析:");
                    ui.label(match last_resolve {
                        Some(_) => format!("{}（每 60s 自动刷新）", now_hms()),
                        None => "解析中…".to_string(),
                    });
                    ui.end_row();

                    ui.label("引擎/系统代理:");
                    let eng = status_raw.contains("engine=running");
                    let px = status_raw.contains("sysproxy=on");
                    ui.label(format!(
                        "引擎 {} · 系统代理 {}",
                        if eng { "运行" } else { "停止" },
                        if px { "已接管(7893)" } else { "未接管" }
                    ));
                    ui.end_row();

                    ui.label("守护回报:");
                    ui.label(if status_raw.is_empty() { "—".into() } else { status_raw });
                    ui.end_row();
                });

            if intended && !effective {
                ui.colored_label(
                    egui::Color32::ORANGE,
                    "⚠ 策略意图为封禁，但守护未生效——请点「启动守护（管理员授权）」并确认上方显示「已生效」。",
                );
            }
            if effective && probe_ok == Some(true) {
                ui.colored_label(
                    egui::Color32::ORANGE,
                    "⚠ 代理在线：经 Clash 远程出口的 Claude 流量不在本层管辖（v0.2 域名平面解决）。直连已封。",
                );
            }

            ui.separator();
            ui.horizontal(|ui| {
                ui.label("模式:");
                let mut m = mode;
                ui.radio_value(&mut m, Mode::Auto, "自动（通路断→封禁）");
                ui.radio_value(&mut m, Mode::ForceBlock, "强制封禁");
                ui.radio_value(&mut m, Mode::ForceAllow, "放行");
                if m != mode {
                    if let Ok(mut c) = self.cfg.lock() {
                        c.mode = m;
                    }
                }
                ui.add_space(16.0);
                ui.label("代理端口:");
                ui.add(egui::TextEdit::singleline(&mut self.port_buf).desired_width(60.0));
            });

            ui.horizontal(|ui| {
                if ui.button("启动守护（管理员授权）").clicked() {
                    self.do_start_daemon();
                }
                if ui.button("停止并解除").clicked() {
                    self.do_stop_daemon();
                }
                if ui.button("立即刷新 IP").clicked() {
                    if let Ok(mut s) = self.shared.lock() {
                        s.refresh_req = true;
                    }
                    push_log(&self.shared, "手动刷新 IP");
                }
                if ui.button("自测拦截效果").clicked() {
                    self.do_self_test();
                }
            });

            if let Some(t) = self_test {
                ui.separator();
                ui.label(egui::RichText::new("自测结果").strong());
                ui.label(egui::RichText::new(t).monospace());
            }

            ui.separator();
            ui.label(
                egui::RichText::new(
                    "v0.2 机制：武装时接管系统 HTTP/HTTPS 代理（127.0.0.1:7893），Claude 域在本机直接 REJECT，\
其余流量链式转发到你的 Clash——浏览器等走系统代理的应用即使开着梯子也会被断。\
仍留的缺口：应用自己硬编码代理指向 Clash（如 curl -x 7890）不经本引擎；直连则由 pf 兜底。",
                )
                .weak()
                .small(),
            );
            ui.label(egui::RichText::new("封禁域名（每行一个，支持任意子域由同一 IP 覆盖）").strong());
            ui.add(
                egui::TextEdit::multiline(&mut self.domains_buf)
                    .desired_rows(5)
                    .desired_width(f32::INFINITY),
            );

            ui.separator();
            ui.label(egui::RichText::new("事件日志").strong());
            egui::ScrollArea::vertical()
                .max_height(180.0)
                .stick_to_bottom(true)
                .show(ui, |ui| {
                    for line in log.iter() {
                        ui.label(egui::RichText::new(line).monospace().small());
                    }
                });
        });
    }
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([780.0, 640.0])
            .with_min_inner_size([640.0, 520.0]),
        ..Default::default()
    };
    eframe::run_native(
        "ClaudeGuard",
        options,
        Box::new(|cc| Ok(Box::new(App::new(cc)))),
    )
}
