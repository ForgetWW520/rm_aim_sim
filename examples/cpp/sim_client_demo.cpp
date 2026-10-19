// MIT License. See ../../LICENSE. Linux-only, no Godot SDK or vision repository required.
#include <nlohmann/json.hpp>
#include <opencv2/highgui.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <fcntl.h>
#include <iostream>
#include <regex>
#include <stdexcept>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>

using Json = nlohmann::json;
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
volatile std::sig_atomic_t exiting = 0;

void on_signal(int) { exiting = 1; }

struct SimImage
{
  cv::Mat bgr;
  Json metadata;
  Clock::time_point received;
};

// Single-thread reference adapter. Do not share this instance between threads without synchronization.
class LocalSimClient
{
public:
  explicit LocalSimClient(const std::string & channel)
  {
    if (!std::regex_match(channel, std::regex("[A-Za-z0-9_-]{1,80}")))
      throw std::runtime_error("Invalid channel");
    const auto path = "/dev/shm/rm_aim_sim_" + channel;
    directory_ = ::open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (directory_ < 0) throw std::runtime_error("Start the simulator first; cannot open " + path);
    struct stat info{};
    if (::fstat(directory_, &info) != 0 || info.st_uid != ::getuid() || (info.st_mode & 0777) != 0700) {
      ::close(directory_);
      throw std::runtime_error("IPC directory must belong to this UID with mode 0700");
    }
    lock_ = ::openat(directory_, "client.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lock_ < 0 || ::flock(lock_, LOCK_EX | LOCK_NB) != 0) {
      if (lock_ >= 0) ::close(lock_);
      ::close(directory_);
      throw std::runtime_error("Cannot lock client.lock; another client may own this channel");
    }
    token_ = std::to_string(::getpid()) + "-" + std::to_string(Clock::now().time_since_epoch().count());
  }

  ~LocalSimClient()
  {
    try { send(false, 0, 0); } catch (...) {}
    ::close(lock_);
    ::close(directory_);
  }

  LocalSimClient(const LocalSimClient &) = delete;
  LocalSimClient & operator=(const LocalSimClient &) = delete;

  bool poll_state()
  {
    auto value = read_json("state.json");
    if (value.value("protocol", "") != "rm_aim_sim/2" || value.value("type", "") != "state")
      return false;
    const double wall = std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
    const double age = wall - value.at("wall_unix_sec").get<double>();
    if (!std::isfinite(age) || age < -0.1 || age > 0.25) return false;
    if (!state_.empty() && value.at("publisher_id") == state_.at("publisher_id") &&
        value.at("publication") == state_.at("publication")) return false;
    if (state_.empty() || context(value) != context(state_)) request_.clear();
    state_ = std::move(value);
    last_state_ = Clock::now();
    return true;
  }

  bool fresh() const
  {
    return !state_.empty() && Clock::now() - last_state_ <= 200ms;
  }

  const Json & state() const { return state_; }

  void send(bool control, double yaw, double pitch, double yaw_vel = 0, double pitch_vel = 0,
            double yaw_acc = 0, double pitch_acc = 0)
  {
    if (state_.empty()) return;
    for (double number : {yaw, pitch, yaw_vel, pitch_vel, yaw_acc, pitch_acc})
      if (!std::isfinite(number) || std::abs(number) > 1000)
        throw std::runtime_error("Command contains invalid angle/feedforward");
    if (sequence_session_ != state_.at("session_id")) {
      sequence_session_ = state_.at("session_id").get<std::string>();
      sequence_ = 0;
    }
    sequence_ = std::max(sequence_, state_.at("ipc").at("last_seq").get<int64_t>() + 1);
    if (sequence_ > 9007199254740991LL) throw std::runtime_error("Sequence exhausted");
    control = control && fresh() && !state_.at("paused").get<bool>() && state_.at("ipc").at("enabled").get<bool>();
    write_json("command.json", {{"protocol", "rm_aim_sim/2"}, {"type", "command"},
      {"publisher_id", state_.at("publisher_id")}, {"session_id", state_.at("session_id")},
      {"seq", sequence_++}, {"control", control}, {"fire", false}, {"yaw", yaw}, {"pitch", pitch},
      {"yaw_vel", yaw_vel}, {"pitch_vel", pitch_vel}, {"yaw_acc", yaw_acc}, {"pitch_acc", pitch_acc}});
  }

  void request_frame()
  {
    if (!request_.empty() || !fresh()) return;
    request_ = token_ + "-" + std::to_string(request_count_++);
    requested_ = Clock::now();
    write_json("request.json", {{"publisher_id", state_.at("publisher_id")}, {"request_id", request_}});
  }

  bool try_frame(SimImage & result)
  {
    if (request_.empty()) return false;
    if (Clock::now() - requested_ > 5s)
      throw std::runtime_error("Frame timeout: use graphical mode, not --headless");
    auto frame = read_json("frame.json");
    if (frame.value("request_id", "") != request_) return false;
    if (!fresh() || frame.value("protocol", "") != "rm_aim_sim/2" ||
        frame.value("type", "") != "frame" || context(frame) != context(state_)) {
      request_.clear();
      return false;
    }
    const double age = state_.at("sim_time").get<double>() - frame.at("sim_time").get<double>();
    if (!std::isfinite(age) || age > 0.2 || age < -0.1) {
      request_.clear();
      return false;
    }
    const int width = frame.at("camera").at("width").get<int>();
    const int height = frame.at("camera").at("height").get<int>();
    const auto encoding = frame.at("encoding").get<std::string>();
    const int channels = encoding == "rgb8" ? 3 : encoding == "rgba8" ? 4 : 0;
    const std::string filename = "frame-" + request_ + ".raw";
    if (!channels || width < 160 || width > 3840 || height < 120 || height > 2160 ||
        frame.at("frame_file") != filename) throw std::runtime_error("Invalid frame layout");
    const size_t bytes = size_t(width) * height * channels;
    if (frame.at("image_bytes").get<size_t>() != bytes) throw std::runtime_error("Invalid image_bytes");
    int fd = ::openat(directory_, filename.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) throw std::runtime_error("Frame disappeared; reconnect after server restart");
    struct stat info{};
    cv::Mat rgb;
    try {
      if (::fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size != static_cast<off_t>(bytes))
        throw std::runtime_error("Frame file size/type mismatch");
      rgb.create(height, width, CV_MAKETYPE(CV_8U, channels));
      read_all(fd, rgb.data, bytes);
    } catch (...) { ::close(fd); throw; }
    ::close(fd);
    cv::cvtColor(rgb, result.bgr, channels == 3 ? cv::COLOR_RGB2BGR : cv::COLOR_RGBA2BGR);
    result.metadata = std::move(frame);
    result.received = Clock::now();
    request_.clear();  // Own BGR storage exists before the next request acknowledges this frame.
    return true;
  }

private:
  int directory_ = -1, lock_ = -1;
  Json state_ = Json::object();
  std::string request_, token_, sequence_session_;
  int64_t sequence_ = 0;
  uint64_t request_count_ = 0;
  Clock::time_point last_state_, requested_;

  static Json context(const Json & packet)
  {
    const auto & camera = packet.at("camera");
    return Json::array({packet.at("publisher_id"), packet.at("session_id"), packet.at("appearance"),
      packet.at("paused"), packet.at("ipc").at("enabled"), camera.at("width"), camera.at("height"),
      camera.at("K"), camera.at("distortion"), camera.at("R_camera2gimbal"), camera.at("t_camera2gimbal")});
  }

  static void read_all(int fd, void * output, size_t bytes)
  {
    auto data = static_cast<char *>(output);
    while (bytes) {
      const auto count = ::read(fd, data, bytes);
      if (count < 0 && errno == EINTR) continue;
      if (count <= 0) throw std::runtime_error("Incomplete file read");
      data += count;
      bytes -= count;
    }
  }

  Json read_json(const char * filename) const
  {
    int fd = ::openat(directory_, filename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return Json::object();
    struct stat info{};
    std::string data;
    try {
      if (::fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 65536)
        throw std::runtime_error("Invalid JSON file size/type");
      data.resize(info.st_size);
      read_all(fd, data.data(), data.size());
    } catch (...) { ::close(fd); throw; }
    ::close(fd);
    auto value = Json::parse(data, nullptr, false);
    return value.is_object() ? value : Json::object();
  }

  void write_json(const char * filename, const Json & value) const
  {
    const std::string temporary = std::string(filename) + ".client.tmp";
    int fd = ::openat(directory_, temporary.c_str(), O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) throw std::runtime_error("Cannot create command/request temporary file");
    try {
      const auto data = value.dump();
      size_t written = 0;
      while (written < data.size()) {
        const auto count = ::write(fd, data.data() + written, data.size() - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) throw std::runtime_error("Incomplete file write");
        written += count;
      }
    } catch (...) {
      ::close(fd);
      ::unlinkat(directory_, temporary.c_str(), 0);
      throw;
    }
    ::close(fd);
    if (::renameat(directory_, temporary.c_str(), directory_, filename) != 0)
      throw std::runtime_error("Cannot atomically publish command/request");
  }
};

int main(int argc, char ** argv)
{
  try {
    std::string channel = "default";
    bool display = true, control = false;
    double yaw = 0, pitch = 0, duration = 5;
    int frames = 0;
    for (int i = 1; i < argc; ++i) {
      const std::string arg = argv[i];
      if (arg == "--help") {
        std::cout << "sim_client_demo [--channel=default] [--no-display] [--frames=30] [--duration=5]\n"
                     "                [--control --yaw=5 --pitch=3]\n"
                     "Angles: degrees. duration=0: unlimited. Never fires. Start graphical simulator first.\n";
        return 0;
      }
      if (arg == "--no-display") { display = false; continue; }
      if (arg == "--control") { control = true; continue; }
      const auto equals = arg.find('=');
      const auto key = arg.substr(0, equals);
      if (equals == std::string::npos) throw std::runtime_error("Use --option=value: " + arg);
      const auto value = arg.substr(equals + 1);
      if (key == "--channel") { channel = value; continue; }
      size_t used = 0;
      const double number = std::stod(value, &used);
      if (used != value.size() || !std::isfinite(number)) throw std::runtime_error("Invalid numeric option");
      if (key == "--yaw") yaw = number;
      else if (key == "--pitch") pitch = number;
      else if (key == "--duration" && number >= 0) duration = number;
      else if (key == "--frames" && number >= 0 && number <= 1000000000 && number == std::floor(number))
        frames = static_cast<int>(number);
      else throw std::runtime_error("Unknown/out-of-range option: " + arg);
    }
    constexpr double degrees_to_radians = 3.14159265358979323846 / 180;
    yaw *= degrees_to_radians;
    pitch *= degrees_to_radians;
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    LocalSimClient client(channel);
    auto begin = Clock::now(), last_state = begin, next_command = begin, next_report = begin;
    int count = 0;
    while (!exiting && (duration == 0 || std::chrono::duration<double>(Clock::now() - begin).count() < duration)) {
      if (client.poll_state()) last_state = Clock::now();
      if (Clock::now() - last_state > 5s) throw std::runtime_error("Simulator state stopped; reconnect client");
      if (Clock::now() >= next_command) {
        client.send(control, yaw, pitch);  // Always fire=false; reference fixed-angle test, not an aimer.
        next_command = Clock::now() + 20ms;
      }
      client.request_frame();
      SimImage sample;
      if (client.try_frame(sample)) {
        ++count;
        // Hand off sample.bgr AND sample.metadata together to your detector/solver.
        if (display) {
          cv::imshow("rm_aim_sim C++ (no fire)", sample.bgr);
          const auto key = cv::waitKey(1);
          if (key == 'q' || key == 27) break;
        }
        if (Clock::now() >= next_report) {
          std::cout << Json{{"type", "cpp_camera_demo"}, {"frames", count},
            {"sim_time", sample.metadata.at("sim_time")}, {"width", sample.bgr.cols}, {"height", sample.bgr.rows},
            {"last_seq", client.state().at("ipc").at("last_seq")}, {"gimbal", client.state().at("gimbal")},
            {"fire", false}}.dump() << std::endl;
          next_report = Clock::now() + 1s;
        }
      }
      if (frames && count >= frames) break;
      std::this_thread::sleep_for(2ms);
    }
    if (display) cv::destroyAllWindows();
    if (!exiting && (!count || (frames && count < frames)))
      throw std::runtime_error("Did not receive requested camera frames; use graphical simulator and sufficient duration");
    std::cout << Json{{"type", "cpp_camera_result"}, {"frames", count}, {"fire", false}}.dump() << std::endl;
    return 0;
  } catch (const std::exception & error) {
    std::cerr << "Simulator client error: " << error.what() << std::endl;
    return 1;
  }
}
