//! Run against the version-matched thurbox kernel; no live UI or trust file.
use thurbox::kernel::host::{LuaHost, Published, RenderContext};
use thurbox::kernel::registry::Registry;
use thurbox::kernel::snapshot::{SessionRow, Snapshot};
use thurbox::kernel::theme::Themes;
use thurbox::session::SessionState;

fn row(name: &str) -> SessionRow {
    SessionRow {
        id: format!("{name}-0000-0000-0000-000000000000"),
        name: name.into(),
        agent: "claude".into(),
        status: SessionState::Idle,
        cwd: None,
        repo: Some("thurbox".into()),
        repos: vec!["thurbox".into()],
        branch: Some(format!("feat/{name}")),
        base_branch: None,
        backend: "local-tmux".into(),
        backend_id: Some("%1".into()),
        remote_host: None,
        agent_session_id: None,
        parent_id: None,
        display_order: None,
        worktree_count: 1,
        git: None,
        stopped: false,
        hook_state: None,
        key: None,
        reports_as: None,
        detected_agent: None,
        shell_backend_id: None,
        member_dirs: Vec::new(),
    }
}

fn sample(root: &std::path::Path) -> Snapshot {
    Snapshot {
        sessions: vec![SessionRow {
            cwd: Some(root.into()),
            ..row("fixture")
        }],
        ..Snapshot::default()
    }
}

fn registry(host: &LuaHost) -> Registry {
    let mut registry = Registry::default();
    let (bindings, settings) = host.declarations();
    registry.declare(bindings, settings);
    registry
}

fn publish(host: &LuaHost, root: &std::path::Path) {
    let themes = Themes::load(None);
    let registry = registry(host);
    let diffs = thurbox::kernel::diff::DiffStore::new();
    let repos = thurbox::kernel::repos::RepoStore::with_hosts(Default::default());
    host.publish(&Published {
        epoch: thurbox::kernel::host::Epoch::always_fresh(),
        snapshot: &sample(root),
        attach_errors: &Default::default(),
        inflight: &[],
        themes: &themes,
        registry: &registry,
        diffs: &diffs,
        links: &Default::default(),
        search: None,
        meta: &Default::default(),
        metrics: &Default::default(),
        status_rows: 0,
        can_open: true,
        inventory: &[],
        ui_dir: "ui",
        settings: &Default::default(),
        repos: &repos,
        wants: &Default::default(),
        focus: None,
        selection: None,
        hovered: None,
        printing: &Default::default(),
    })
    .expect("publish");
}

fn paint(host: &LuaHost, index: usize) -> String {
    let result = host
        .render(
            index,
            RenderContext {
                width: 100,
                height: 30,
                focused: true,
                elapsed: 0.0,
                frame: 0,
            },
        )
        .expect("render files");
    format!("{:?}", result.node)
}

#[test]
fn files_grant_navigation_and_reload() {
    let ui = std::path::PathBuf::from(std::env::var("FILES_TEST_UI").unwrap());
    let root = ui.parent().unwrap().join("runtime-fixture");
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(root.join("src/child.txt"), "child").unwrap();
    let host = LuaHost::new(ui);
    assert!(host.error.is_none(), "{:?}", host.error);
    let index = host.plugins.iter().position(|p| p.name == "files").unwrap();
    let path = host.plugins[index].path.clone();
    host.set_shared_string("selected", "fixture-0000-0000-0000-000000000000");
    publish(&host, &root);
    let text = paint(&host, index);
    assert!(text.contains("not trusted to list files"), "{text}");
    assert!(text.contains("Interface"), "{text}");
    for action in [
        "files.next",
        "files.previous",
        "files.expand",
        "files.collapse",
        "files.toggle",
        "files.menu",
        "files.reload",
    ] {
        assert!(host.on_action(index, action).expect(action));
    }
    let click = thurbox::kernel::host::Click {
        id: Some("src".into()),
        classes: vec![],
        role: Some("row".into()),
        x: 0,
        y: 0,
        w: 100,
        h: 30,
        screen_x: 0,
        screen_y: 0,
        dragging: false,
        clicks: 1,
    };
    assert!(!host.on_click(index, &click).expect("untrusted click"));
    assert!(!host.on_context(index, &click).expect("untrusted context"));
    // This is an in-memory grant in a disposable host, never an operator setting.
    host.set_trusted(vec![path.clone()]);
    publish(&host, &root);
    let text = paint(&host, index);
    assert!(text.contains("src"), "{text}");
    assert!(!text.contains("child.txt"), "{text}");
    host.on_action(index, "files.expand").unwrap();
    assert!(paint(&host, index).contains("child.txt"));
    host.on_action(index, "files.collapse").unwrap();
    assert!(!paint(&host, index).contains("child.txt"));
    std::fs::write(root.join("added.txt"), "added").unwrap();
    assert!(!paint(&host, index).contains("added.txt"));
    host.on_action(index, "files.reload").unwrap();
    assert!(paint(&host, index).contains("added.txt"));
    assert!(host.on_click(index, &click).unwrap());
    assert!(paint(&host, index).contains("child.txt"));
    assert!(host.on_click(index, &click).unwrap());
    assert!(!paint(&host, index).contains("child.txt"));
    host.set_trusted(vec![]);
    publish(&host, &root);
    assert!(paint(&host, index).contains("not trusted to list files"));
    std::fs::write(root.join("after-grant.txt"), "added").unwrap();
    host.set_trusted(vec![path]);
    publish(&host, &root);
    assert!(paint(&host, index).contains("after-grant.txt"));
    std::fs::remove_dir_all(&root).unwrap();
    host.on_action(index, "files.reload").unwrap();
    assert!(paint(&host, index).contains("unreadable:"));
    for action in ["files.next", "files.expand", "files.toggle", "files.menu"] {
        assert!(host
            .on_action(index, action)
            .expect("unreadable navigation"));
    }
    assert!(!host.on_click(index, &click).unwrap());
    assert!(!host.on_context(index, &click).unwrap());
}
