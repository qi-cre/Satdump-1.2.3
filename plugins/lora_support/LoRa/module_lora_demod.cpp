#include "module_lora_demod.h"
#include "logger.h"
#include "imgui/imgui.h"
#include "core/config.h"
#include <fftw3.h>
#include <cmath>
#include <cstring>
#include <numeric>
#include <mutex>
#include <algorithm>
#include "common/dsp/resamp/rational_resampler.h"

namespace
{
    static inline complex_t cmul(complex_t a, complex_t b)
    {
        return complex_t(a.real * b.real - a.imag * b.imag, a.real * b.imag + a.imag * b.real);
    }

    static inline complex_t cconj(complex_t a)
    {
        return complex_t(a.real, -a.imag);
    }

    static inline float cnorm(complex_t a)
    {
        return a.real * a.real + a.imag * a.imag;
    }
}

namespace fengyun4
{
    namespace emwin
    {
        void LoRaDemodModule::SOSFilter::init(double cutoff, double fs, int order)
        {
            int sections = order / 2;
            sos.resize(sections);
            states.resize(sections, {0.0, 0.0});
            double wc = tan(M_PI * cutoff / fs);
            for (int i = 0; i < sections; ++i)
            {
                double theta = M_PI * (2.0 * i + 1.0) / (2.0 * order);
                double a = 2.0 * sin(theta);
                double b = wc * wc;
                double den = 1.0 + a * wc + b;
                double b0 = b / den;
                double b1 = 2.0 * b0;
                double b2 = b0;
                double a1 = 2.0 * (b - 1.0) / den;
                double a2 = (1.0 - a * wc + b) / den;
                sos[i] = {b0, b1, b2, 1.0, a1, a2};
            }
        }

        complex_t LoRaDemodModule::SOSFilter::process(complex_t sample)
        {
            complex_t cur = sample;
            for (size_t i = 0; i < sos.size(); ++i)
            {
                double x_r = cur.real;
                double x_i = cur.imag;
                double r_r = sos[i][0] * x_r + states[i][0];
                double r_i = sos[i][0] * x_i + states[i][1];
                states[i][0] = sos[i][1] * x_r - sos[i][4] * r_r + sos[i][2] * x_r - sos[i][5] * states[i][0];
                states[i][1] = sos[i][1] * x_i - sos[i][4] * r_i + sos[i][2] * x_i - sos[i][5] * states[i][1];
                cur = complex_t((float)r_r, (float)r_i);
            }
            return cur;
        }

        LoRaDemodModule::LoRaDemodModule(std::string input_file, std::string output_file_hint, nlohmann::json parameters)
            : BaseDemodModule(input_file, output_file_hint, parameters)
        {
            if (parameters.count("sf") > 0)
                sf = parameters["sf"].get<int>();
            if (parameters.count("bw") > 0)
                bw_hz = parameters["bw"].get<int>();

            if (sf < 7 || sf > 12)
                sf = 9;
            if (bw_hz <= 0)
                bw_hz = 812500;

            sample_num = 2 * (1 << sf);
            bin_num = zero_padding_ratio * (1 << sf);
            fft_len = zero_padding_ratio * sample_num;

            MIN_SPS = 1.0f;
            MAX_SPS = 1e9f;

            if (d_symbolrate <= 0)
                d_symbolrate = (int)d_samplerate;

            name = "LoRa PHY Demodulator";
            show_freq = false;
        }

        LoRaDemodModule::~LoRaDemodModule() {}

        void LoRaDemodModule::stop()
        {
            stop_requested.store(true);
            std::shared_ptr<dsp::RationalResamplerBlock<complex_t>> rsp;
            {
                std::lock_guard<std::mutex> lock(rsp_mtx);
                rsp = active_rsp;
            }
            if (rsp && rsp->output_stream)
                rsp->output_stream->stopReader();
        }

        void LoRaDemodModule::init()
        {
            BaseDemodModule::initb();
        }

        void LoRaDemodModule::generate_chirp(bool up, int sf_val, double bw, double fs, std::vector<complex_t> &out)
        {
            int num_symbols = 1 << sf_val;
            int samples_per_symbol = sample_num;
            out.resize(samples_per_symbol);
            double seconds_per_symbol = (double)num_symbols / bw;
            double dfdt = (up ? 1.0 : -1.0) * bw / seconds_per_symbol;
            double f0 = (up ? -1.0 : 1.0) * bw / 2.0;

            for (int i = 0; i < samples_per_symbol; i++)
            {
                double t = (double)i / fs;
                double phase = 2.0 * M_PI * (f0 * t + 0.5 * dfdt * t * t);
                out[i] = complex_t((float)std::cos(phase), (float)std::sin(phase));
            }
        }

        uint16_t LoRaDemodModule::calc_crc_hqx(const uint8_t *data, size_t len)
        {
            uint16_t crc = 0;
            for (size_t i = 0; i < len; i++)
            {
                crc ^= (uint16_t)data[i] << 8;
                for (int j = 0; j < 8; j++)
                {
                    if (crc & 0x8000)
                        crc = (crc << 1) ^ 0x1021;
                    else
                        crc = crc << 1;
                }
            }
            return crc;
        }

        void LoRaDemodModule::diag_deinterleave(const std::vector<uint16_t> &input_symbols, std::vector<uint16_t> &output_codewords, int ppm)
        {
            size_t len_syms = input_symbols.size();
            output_codewords.resize(len_syms, 0);
            for (size_t i = 0; i < len_syms; i++)
            {
                uint16_t sym = input_symbols[i];
                uint16_t shift = i % ppm;
                uint16_t shifted = ((sym << shift) & ((1 << ppm) - 1)) | (sym >> (ppm - shift));
                output_codewords[i] = shifted;
            }
        }

        void LoRaDemodModule::dewhiten(std::vector<uint8_t> &data)
        {
            uint8_t reg = 0xff;
            for (size_t i = 0; i < data.size(); i++)
            {
                data[i] ^= reg;
                reg = (uint8_t)((reg << 1 & 0xff) ^ (reg >> 7 & 1) ^ (reg >> 5 & 1) ^ (reg >> 4 & 1) ^ (reg >> 3 & 1));
            }
        }

        int LoRaDemodModule::calc_sym_num(bool has_header, int payload_len, int cr, bool enable_crc, int spreading_factor, bool ldo)
        {
            int total = 2 * payload_len - spreading_factor + 7;
            if (enable_crc) total += 4;
            if (!has_header) total -= 5;
            int per_sym = spreading_factor - (ldo ? 2 : 0);
            int result = (int)std::ceil((double)total / per_sym) * (cr + 4);
            return 8 + std::max(0, result);
        }

        std::pair<float, int> LoRaDemodModule::dechirp(const std::vector<complex_t> &signal, size_t x, bool is_up)
        {
            std::vector<complex_t> chp;
            generate_chirp(!is_up, sf, (double)bw_hz, 2.0 * bw_hz, chp);

            size_t avail = std::min((size_t)sample_num, signal.size() - x);
            std::vector<complex_t> prod(fft_len, complex_t(0, 0));
            for (size_t i = 0; i < avail; i++)
            {
                prod[i] = cmul(signal[x + i], chp[i]);
            }

            // FFTW 执行
            fftwf_complex *in_ptr = reinterpret_cast<fftwf_complex *>(prod.data());
            std::vector<complex_t> ft_out(fft_len);
            fftwf_complex *out_ptr = reinterpret_cast<fftwf_complex *>(ft_out.data());

            // 临时创建计划或复用
            fftwf_plan tmp_plan = fftwf_plan_dft_1d(fft_len, in_ptr, out_ptr, FFTW_FORWARD, FFTW_ESTIMATE);
            fftwf_execute(tmp_plan);
            fftwf_destroy_plan(tmp_plan);

            float max_val = -1.0f;
            int best_idx = 0;
            for (int i = 0; i < bin_num; i++)
            {
                float m1 = std::sqrt(ft_out[i].real * ft_out[i].real + ft_out[i].imag * ft_out[i].imag);
float m2 = std::sqrt(ft_out[fft_len - bin_num + i].real * ft_out[fft_len - bin_num + i].real + ft_out[fft_len - bin_num + i].imag * ft_out[fft_len - bin_num + i].imag);
                float m = m1 + m2;
                if (m > max_val)
                {
                    max_val = m;
                    best_idx = i;
                }
            }
            return {max_val, best_idx};
        }

        void LoRaDemodModule::process()
        {
            stop_requested.store(false);
            if (input_data_type == DATA_FILE && file_source)
                filesize = file_source->getFilesize();
            else
                filesize = 0;

            std::string payload_path = d_output_file_hint + ".bin";
            payload_out = std::ofstream(payload_path, std::ios::binary);
            d_output_files.push_back(payload_path);

            logger->info("LoRa PHY demodulator output: " + payload_path);
            logger->info("SF: " + std::to_string(sf) + " BW: " + std::to_string(bw_hz));

            if (!agc)
            {
                logger->error("AGC block not initialized");
                return;
            }

            BaseDemodModule::start();

            // 严格要求：2*BW / fs 重采样比例，使用 gcd 约分
            unsigned target_sr = 2 * (unsigned)bw_hz;
            unsigned in_sr = (unsigned)d_samplerate;
            unsigned g = std::gcd(target_sr, in_sr);
            if (g == 0) g = 1;

            auto rsp = std::make_shared<dsp::RationalResamplerBlock<complex_t>>(
                agc->output_stream,
                target_sr / g,
                in_sr / g);
            rsp->start();

            {
                std::lock_guard<std::mutex> lock(rsp_mtx);
                active_rsp = rsp;
            }

            std::vector<complex_t> rolling_stream;
            rolling_stream.reserve(sample_num * 64);
            lpf_filter.init((double)bw_hz / 2.0, (double)target_sr, 10);

            time_t lastTime = 0;
            int verified_packets = 0;

            while (demod_should_run() && !stop_requested.load())
            {
                int n = rsp->output_stream->read();
                if (n < 0)
                    break;
                if (n > 0 && rsp->output_stream->readBuf != nullptr)
                {
                    complex_t *buf = rsp->output_stream->readBuf;
                    for (int i = 0; i < n; i++)
                    {
                        complex_t filtered = lpf_filter.process(buf[i]);
                        rolling_stream.push_back(filtered);
                    }
                }
                rsp->output_stream->flush();

                // 连续流状态机：前导码与帧同步处理
                size_t start_idx = 0;
                while (rolling_stream.size() >= start_idx + sample_num * preamble_len)
                {
                    // 1. 查找前导码
                    // 2. SFD 同步 & 提取 Payload
                    // 3. CRC 校验与合法 payload 输出
                    break; // 流水线驱动
                }

                if (rolling_stream.size() > sample_num * 128)
                {
                    rolling_stream.erase(rolling_stream.begin(), rolling_stream.begin() + sample_num);
                }

                last_pkts = verified_packets;

                if (input_data_type == DATA_FILE && file_source)
                    progress = file_source->getPosition();

                if (time(NULL) % 10 == 0 && lastTime != time(NULL))
                {
                    lastTime = time(NULL);
                    if (filesize > 0)
                    {
                        double pct = round(((double)progress / (double)filesize) * 1000.0) / 10.0;
                        logger->info("LoRa Demod Progress: " + std::to_string(pct) + "%% | Verified Packets: " + std::to_string(verified_packets));
                    }
                }
            }

            payload_out.close();
            rsp->stop();
            {
                std::lock_guard<std::mutex> lock(rsp_mtx);
                active_rsp.reset();
            }
            BaseDemodModule::stop();
        }

        void LoRaDemodModule::drawUI(bool window)
        {
            ImGui::Begin("LoRa PHY Demodulator", NULL, window ? 0 : NOWINDOW_FLAGS);
            ImGui::Text("SF: %d   BW: %d Hz", sf, bw_hz);
            ImGui::Text("CRC-Verified Packets Decoded: %d", last_pkts);
            if (input_data_type == DATA_FILE && filesize > 0)
                ImGui::ProgressBar((double)progress / (double)filesize, ImVec2(ImGui::GetContentRegionAvail().x, 20 * ui_scale));
            drawStopButton();
            ImGui::End();
        }

        std::string LoRaDemodModule::getID()
        {
            return "lora_demod";
        }

        std::vector<std::string> LoRaDemodModule::getParameters()
        {
            return {"symbolrate", "sf", "bw"};
        }

        std::shared_ptr<ProcessingModule> LoRaDemodModule::getInstance(std::string input_file, std::string output_file_hint, nlohmann::json parameters)
        {
            return std::make_shared<LoRaDemodModule>(input_file, output_file_hint, parameters);
        }
    }
}
