cmake_minimum_required(VERSION 3.16)
project(rm_sim_client_example LANGUAGES CXX)

find_package(OpenCV REQUIRED COMPONENTS core imgproc highgui)
find_package(nlohmann_json 3.2 REQUIRED)

add_executable(sim_client_demo sim_client_demo.cpp)
target_compile_features(sim_client_demo PRIVATE cxx_std_17)
target_compile_options(sim_client_demo PRIVATE -Wall -Wextra -Wpedantic)
target_include_directories(sim_client_demo PRIVATE ${OpenCV_INCLUDE_DIRS})
target_link_libraries(sim_client_demo PRIVATE ${OpenCV_LIBS} nlohmann_json::nlohmann_json)
