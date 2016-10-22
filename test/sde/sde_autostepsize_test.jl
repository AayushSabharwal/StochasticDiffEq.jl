using DifferentialEquations, Plots
srand(100)
prob = prob_sde_2Dlinear

## Solve and plot
println("Solve and Plot")
#Let the solver determine the initial stepsize for you!
sol =solve(prob::SDEProblem,save_timeseries=true,alg=:SRI,adaptive=true)

TEST_PLOT && plot(sol,plot_analytic=true)
#gui()

#Make sure it does a good job
sol.ts[2] > 1e-7
