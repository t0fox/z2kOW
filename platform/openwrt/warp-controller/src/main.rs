mod cli;

fn main() {
    warp_controller::process::start_operation();
    if let Err(error) = cli::run() {
        eprintln!("z2k-warp-controller: {error}");
        std::process::exit(1);
    }
}
