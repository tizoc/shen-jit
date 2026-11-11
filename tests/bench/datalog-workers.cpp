// The generated program and this harness use the same 32-bit domain as Shen.
// Facts are in memory before the clock. Each sample builds a fresh database,
// inserts facts, evaluates and reads sizes. Destruction is reported separately,
// matching the Shen clock, which stops after counts and leaves GC to the VM.
#define __EMBEDDED_SOUFFLE__
#include "program.cpp"
#include <chrono>
#include <fstream>
#include <iomanip>
#include <memory>

static_assert(sizeof(souffle::RamDomain) == 4, "the comparison requires 32-bit domains");

int main(int argc, char** argv) {
    if (argc != 4) return 2;
    const int workers = std::stoi(argv[1]);
    const int rounds = std::stoi(argv[2]);
    std::ifstream input(std::string(argv[3]) + "/edge.facts");
    if (!input) return 3;
    std::vector<std::pair<souffle::RamDomain, souffle::RamDomain>> facts;
    souffle::RamDomain a, b;
    while (input >> a >> b) facts.emplace_back(a, b);
    for (int i = 0; i <= rounds; ++i) {
        auto start = std::chrono::steady_clock::now();
        double seconds;
        std::chrono::steady_clock::time_point cleanup;
        std::vector<std::pair<std::string, std::size_t>> counts;
        {
            std::unique_ptr<souffle::SouffleProgram> p(souffle::ProgramFactory::newInstance("program"));
            if (!p) return 4;
            p->setNumThreads(workers);
            auto* edge = p->getRelation("edge");
            for (auto [x, y] : facts) {
                souffle::tuple t(edge);
                t << x << y;
                edge->insert(t);
            }
            p->run();
            for (auto* r : p->getAllRelations()) counts.emplace_back(r->getName(), r->size());
            seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
            if (i == 0 && std::getenv("DATALOG_WORKERS_DUMP")) p->printAll(argv[3]);
            cleanup = std::chrono::steady_clock::now();
        }
        auto cleanupSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - cleanup).count();
        std::cout << (i == 0 ? "FIRST " : "SAMPLE ") << std::setprecision(10) << seconds;
        for (auto [name, n] : counts) std::cout << " " << name << "=" << n;
        std::cout << "\n";
        std::cout << "CLEANUP " << cleanupSeconds << "\n";
    }
}
