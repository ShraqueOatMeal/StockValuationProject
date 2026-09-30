<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('user_dcf_scenarios', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            $table->string('ticker', 12)->index();
            $table->string('scenario_name', 50); // e.g. Base, Bull, Bear
            $table->decimal('base_fcf', 20, 2);
            $table->decimal('growth_stage_1', 6, 4); // 0.1250 = 12.5%
            $table->decimal('terminal_growth', 6, 4);
            $table->decimal('wacc', 6, 4);
            $table->decimal('cash_and_equivalents', 20, 2);
            $table->decimal('total_debt', 20, 2);
            $table->decimal('shares_outstanding', 20, 2);
            $table->decimal('calculated_fair_value', 10, 2);
            $table->text('notes')->nullable();
            $table->timestamps();

            $table->unique(['user_id', 'ticker', 'scenario_name']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('user_dcf_scenarios');
    }
};
